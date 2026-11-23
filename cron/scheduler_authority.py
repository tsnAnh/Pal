"""Transport-only cron execution; output/delivery remain with the firing scheduler."""
import asyncio
import hashlib
import json
import logging
import uuid
from datetime import datetime, timedelta

from hermes_time import now as _now

DEFER_BOUND_SECONDS = 1800
DRAIN_REASON = 'runtime_draining'


class CronExecutionUnknown(RuntimeError):
    """The owner may have accepted this fire; never book it as failed or re-fire."""


class CronDeferred(RuntimeError):
    pass


def is_drain_refusal(exc):
    return DRAIN_REASON in (getattr(exc, 'reason', None), str(exc)) or getattr(exc, 'state', None) == 'draining'


def run_record(job_id, execution_id, scheduled, outcome, cause):
    line = f'{outcome}: {cause} (run {execution_id}, scheduled {scheduled or "unknown"})'
    return f'# Cron Job: {job_id} ({outcome.upper()})\n\n{line}\n', line


def settle_unverified_fire(job, execution_id, exc):
    from cron.executions import give_up_execution
    if isinstance(exc, CronDeferred):
        give_up_execution(execution_id, reason=str(exc))
        logging.getLogger('cron.scheduler').warning('Cron %s run %s deferred: %s', job['id'], execution_id, exc)
        return False
    from cron.jobs_error_text import sanitize_persisted_error
    # One sanitized string for both stores: _lift_pause matches the pause by its reason.
    reason = sanitize_persisted_error(str(exc)) or 'unverified admission'
    pause_for_unknown(job['id'], execution_id, reason)
    give_up_execution(execution_id, reason=reason)
    logging.getLogger('cron.scheduler').error('Cron %s paused with unverified admission: %s', job['id'], exc)
    return False


def journal_path(job_id, request_id):
    from hermes_constants import get_hermes_home
    key = hashlib.sha256(json.dumps([job_id, request_id]).encode()).hexdigest()
    return get_hermes_home() / 'cron' / 'admissions' / (key + '.json')


def _pause_identity(paused):
    """The exact pause this recovery uncertainty caused, so only that pause is ever lifted."""
    return {'paused_at': paused.get('paused_at'), 'reason': paused.get('paused_reason')} if paused else True


def replayable_completions(job_id, completions):
    """The recorded completion ids whose admission journal still exists: only journal recovery
    can replay a completion into ``mark_job_run``, so an id without one is a dead tombstone."""
    return [eid for eid in completions or () if journal_path(job_id, eid).exists()]


def pause_for_unknown(job_id, execution_id, reason):
    """The firer pauses the job for this fire's unverified admission and records that exact pause
    on the fire's journal, so the receipt that later proves the run terminal can lift it."""
    from cron.jobs import pause_job
    from utils import atomic_json_write
    paused = pause_job(job_id, reason=reason)
    journal = journal_path(job_id, execution_id)
    if paused and journal.exists():
        record = json.loads(journal.read_text(encoding='utf-8-sig'))
        record['pause_recorded'] = _pause_identity(paused)
        atomic_json_write(journal, record, mode=0o600, fsync_dir=True)


def _lift_pause(job_id, pause):
    """A verified terminal receipt resolved the uncertainty that paused the schedule: resume it iff
    the job is still held by exactly that pause (an operator's own pause/resume is never touched)."""
    from cron.jobs import get_job, resume_job
    job = get_job(job_id) if isinstance(pause, dict) else None
    if (job is not None and job.get('state') == 'paused'
            and (job.get('paused_at'), job.get('paused_reason')) == (pause['paused_at'], pause['reason'])):
        try:
            resume_job(job_id)
        except ValueError:  # a one-shot whose instant has passed stays paused for the operator
            pass


def run_canonical_job(job, *, extra_prompt=None, cancel_event=None, execution_id=None):
    from gateway.session_cron import owner_for_home, operation
    from hermes_cli.gateway_client import connect_gateway
    from hermes_constants import get_hermes_home
    from storage_user_copy import error_type_name
    from utils import atomic_json_write

    request_id = execution_id or job.get('execution_id')
    if not request_id:
        request_id = job['execution_id'] = uuid.uuid4().hex
    params = {'job_id': job['id'], 'request_id': request_id,
              'extra_prompt': extra_prompt}
    root = get_hermes_home() / 'cron' / 'admissions'
    journal = journal_path(params['job_id'], params['request_id'])
    record = {'params': params, 'receipt': None}
    if journal.exists():
        record = json.loads(journal.read_text(encoding='utf-8-sig'))
        if record['params'] != params:
            raise CronExecutionUnknown('cron admission identity conflict')
    attempted = journal.exists()
    owner = owner_for_home(get_hermes_home())

    def write_journal():
        root.mkdir(parents=True, exist_ok=True)
        atomic_json_write(journal, record, mode=0o600, fsync_dir=True)

    async def save():
        # ``observe`` runs on the owner loop when this process owns the profile: the fsynced journal
        # write (file and directory) waits in a worker, and still completes before the next step.
        await asyncio.to_thread(write_journal)

    async def defer():
        held = record.get('deferred') or {}
        record['deferred'] = dict(held, reason=DRAIN_REASON, since=held.get('since') or _now().isoformat())
        record['job'] = dict(job)
        await save()
        raise CronDeferred('gateway was draining; fire stays pending under its run id')

    async def observe(call):
        nonlocal attempted, reached_owner
        attempted = reached_owner = True
        await save()
        try:
            receipt = await call('submit', params)
        except Exception as exc:
            from hermes_cli.gateway_client import GatewayRPCError
            # A returned owner exception is definite; a transport disconnect is not. Even an
            # owner error after commit must retain the admitted identity, so verify its absence.
            if owner is not None or isinstance(exc, GatewayRPCError):
                state = await call('recover', params)
                if state['status'] == 'missing':
                    if is_drain_refusal(exc):
                        await defer()
                    error = f'{error_type_name(exc)}: {exc}'
                    result = [False, f'# Cron Job: {job["id"]} (FAILED)\n\n{error}\n', '', error]
                    record['refusal'] = result
                    record['job'] = dict(job)
                    await save()
                    return tuple(result)
                if state['status'] not in {'queued', 'started', 'terminal'}:
                    raise
                # Admitted before the answer was lost: observe it through the recovered receipt.
                receipt = {'session_id': state['session_id'], 'admission_id': state['admission_id']}
            else:
                raise
        record['receipt'] = receipt
        await save()
        delay, progress = .1, None
        while True:
            if cancel_event is not None and cancel_event.is_set():
                await call('cancel', receipt)
            state = await call('status', receipt)
            if state.get('progress_at') not in (None, progress):
                # The owner's agent is still working: refresh OUR ledger row (the owner's stamp is
                # fenced to the row's owner), once per owner stamp, so the stale-claim sweep measures
                # the run's silence. A wedged owner stops stamping and the sweep still fires.
                from cron.executions import touch_execution_progress
                progress = state['progress_at']
                await asyncio.to_thread(touch_execution_progress, request_id)
            if state['status'] == 'terminal':
                job.update(state.get('job_flags') or {})
                return tuple(state['result'])
            if state['status'] == 'unknown':
                raise CronExecutionUnknown('unknown_execution: cron admission was not replayed')
            await asyncio.sleep(delay)
            delay = min(delay * 2, 2.0)

    reached_owner = False

    async def remote():
        try:
            async with connect_gateway() as client:
                return await observe(lambda op, data: client.rpc('cron.' + op, **data))
        except Exception as exc:
            if reached_owner or not is_drain_refusal(exc):
                raise
            await defer()

    try:
        if owner is not None:
            authority, loop = owner
            try:
                current = asyncio.get_running_loop()
            except RuntimeError:
                current = None
            if current is loop:
                raise RuntimeError('cron synchronous execution must run off the owner event loop')
            return asyncio.run_coroutine_threadsafe(
                observe(lambda op, data: operation(authority, op, data)), loop).result()
        return asyncio.run(remote())
    except CronDeferred:
        raise
    except Exception as exc:
        if attempted:
            raise CronExecutionUnknown(f'Cron execution unverified; reconcile {journal}: {exc}') from exc
        error = f'{error_type_name(exc)}: {exc}'
        return False, f'# Cron Job: {job["id"]} (FAILED)\n\n{error}\n', '', error


def _defer_deadline(record, row, journal, job):
    held = (record.get('deferred') or {}).get('since') or (row or {}).get('claimed_at')
    since = datetime.fromisoformat(held) if held else datetime.fromtimestamp(journal.stat().st_mtime).astimezone()
    deadline = since + timedelta(seconds=DEFER_BOUND_SECONDS)
    from cron.jobs import _parse_aware
    slot = _parse_aware(job.get('next_run_at')) if job.get('schedule', {}).get('kind') in {'cron', 'interval'} else None
    return since, min(deadline, slot) if slot is not None and slot > since else deadline


def _submit_pending(params, owner, allow_connect):
    from gateway.session_cron import operation
    from hermes_cli.gateway_client import connect_gateway

    if owner is not None:
        return asyncio.run_coroutine_threadsafe(operation(owner[0], 'submit', params), owner[1]).result(timeout=60)
    if not allow_connect:
        return None

    async def remote():
        async with connect_gateway() as client:
            return await client.rpc('cron.submit', **params)
    return asyncio.run(remote())


def _resubmit_or_settle(journal, record, params, row, job, owner, allow_connect):
    from hermes_cli.gateway_client import GatewayClientError, GatewayRPCError
    from persistence.core.errors import AuthorityRefusal
    from utils import atomic_json_write

    now = _now()
    since, deadline = _defer_deadline(record, row, journal, job)
    cause = 'gateway was draining' if (record.get('deferred') or {}).get('reason') == DRAIN_REASON else 'the owner never admitted this fire'
    scheduled = (row or {}).get('scheduled_instant') or (row or {}).get('claimed_at')

    def terminal(outcome, detail):
        output, error = run_record(params['job_id'], params['request_id'], scheduled, outcome, detail)
        return {'status': 'terminal', 'job': job, 'result': [False, output, '', error]}

    if now >= deadline:
        minutes = max(1, round((now - since).total_seconds() / 60))
        return terminal('skipped', f'{cause} for {minutes} min')
    try:
        receipt = _submit_pending(params, owner, allow_connect)
    except (AuthorityRefusal, GatewayRPCError) as exc:
        if is_drain_refusal(exc):
            return None
        from storage_user_copy import error_type_name
        return terminal('failed', f'resubmit refused: {error_type_name(exc)}: {exc}')
    except (GatewayClientError, OSError, TimeoutError):
        return None
    if receipt is not None:
        record['receipt'] = receipt
        record['deferred'] = dict(record.get('deferred') or {}, retried_at=now.isoformat())
        atomic_json_write(journal, record, mode=0o600, fsync_dir=True)
        logging.getLogger(__name__).info('Cron fire %s of job %s submitted again after %s', params['request_id'],
                                         params['job_id'], cause)
    return None


def reconcile_pending(*, allow_connect=True):
    """Observe prepared fires; never submit missing or interrupted work.

    With allow_connect=False, a headless tick leaves durable receipts for the next
    live owner instead of ensuring or spawning a gateway.
    """
    from gateway.session_cron import owner_for_home, operation
    from hermes_constants import get_hermes_home
    from hermes_cli.gateway_client import connect_gateway
    from cron.executions import FIRER_FINISHED_STATES, execution_owner_live, get_execution
    from cron.jobs import get_job, pause_job
    from cron.scheduler import (_RunDelivery, _FireOwnership, _apply_agent_failure_marker,
                                _save_compose_deliver)
    from cron.scheduler_bookkeeping import fail_empty_response, finish_completed_run
    from utils import atomic_json_write
    root = get_hermes_home() / 'cron' / 'admissions'
    for journal in sorted(root.glob('*.json')):
        try:
            record = json.loads(journal.read_text(encoding='utf-8-sig'))
            params = record['params']
            if journal != journal_path(params['job_id'], params['request_id']):
                raise ValueError('cron journal identity conflict')
            if execution_owner_live(params['request_id'], params['job_id']):
                # Its firer (this process included) still owns the row and its tail: re-saving the
                # output or re-marking the job on every tick would duplicate its side effects.
                continue
            row = get_execution(params['request_id'])
            if row is not None and row['job_id'] == params['job_id'] and row['status'] in FIRER_FINISHED_STATES:
                # The firer booked this attempt's terminal outcome itself (ownership lost, shutdown
                # interrupt, a crashed tail): the receipt is not a result to save or deliver again.
                journal.unlink(missing_ok=True)
                continue
            if 'refusal' in record:
                state = {'status': 'terminal', 'result': record['refusal'], 'job': record['job']}
            else:
                owner = owner_for_home(get_hermes_home())
                if owner is None and not allow_connect:
                    continue
                async def observe():
                    if owner is not None:
                        return await operation(owner[0], 'recover', params)
                    async with connect_gateway() as client:
                        return await client.rpc('cron.recover', **params)
                if owner is not None:
                    state = asyncio.run_coroutine_threadsafe(observe(), owner[1]).result(timeout=20)
                else:
                    state = asyncio.run(observe())
            if state['status'] == 'missing':
                # Never admitted (a drain refused it, or the firer died before its submit): resubmitted
                # under the same run id until its bound, then booked skipped. Only ``unknown`` pauses.
                current = get_job(params['job_id'])
                if current is None:
                    journal.unlink(missing_ok=True)
                    continue
                state = _resubmit_or_settle(journal, record, params, row, current, owner, allow_connect)
                if state is None:
                    continue
            if state['status'] != 'terminal':
                if state['status'] == 'unknown' and not record.get('pause_recorded'):
                    reason = 'Canonical cron unknown; no automatic re-execution'
                    record['pause_recorded'] = _pause_identity(pause_job(params['job_id'], reason=reason))
                    atomic_json_write(journal, record, mode=0o600, fsync_dir=True)
                continue
            success, output, answer, error = state['result']
            job = dict(state['job'], **(state.get('job_flags') or {}))
            job['execution_id'] = params['request_id']
            # The same result verdicts as the ordinary tail: an agent-declared [CRON_FAILURE] and a
            # blank answer are failures, whichever process books them.
            success, error, declared = _apply_agent_failure_marker(job, success, error, answer)
            delivery = _RunDelivery(job, success, error, agent_declared=declared)
            # The canonical receipt supplies the result; a dead scheduler's fire claim does not
            # authorize replay and must not prevent finishing its durable bookkeeping.
            fence = _FireOwnership(dict(job, fire_claim=None))
            _save_compose_deliver(delivery, fence, answer, output, adapters=None, loop=None,
                                 verbose=False, execution_token=None)
            fail_empty_response(delivery, answer)
            if finish_completed_run(delivery, None, params['request_id'], recovered=True):
                _lift_pause(params['job_id'], record.get('pause_recorded'))
        except Exception:
            logging.getLogger(__name__).warning('Cron receipt recovery deferred: %s', journal, exc_info=True)
