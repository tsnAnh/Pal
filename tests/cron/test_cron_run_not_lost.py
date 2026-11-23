import asyncio
import json
from contextlib import asynccontextmanager
from datetime import timedelta
from types import SimpleNamespace

from cron import executions, jobs, scheduler, scheduler_authority
from gateway import run, session_cron
from gateway.config import GatewayConfig
from gateway.session import SessionStore
from gateway.session_authority import SessionAuthority
from hermes_cli import gateway_client
from hermes_time import now as hermes_now
from persistence_assembly import open_persistence, profile_scope

MAX_DEFER_MINUTES = 30


def _owner(tmp_path, monkeypatch):
    monkeypatch.setenv('HERMES_HOME', str(tmp_path))
    monkeypatch.setattr(run, '_load_gateway_config', lambda: {'model': {}, 'platform_toolsets': {'cli': []}})
    db = open_persistence(profile_scope(home=tmp_path))
    runner = SimpleNamespace(_draining=False, session_store=SessionStore(tmp_path / 'sessions', GatewayConfig()), adapters={})
    authority = SessionAuthority(runner, profile_id=str(tmp_path), instance_id='test', persistence=db,
                                 epoch=db.runtime.begin_epoch(instance_id='test'))
    monkeypatch.setattr(authority, '_schedule', lambda ref: None)
    runner.session_authority = authority
    return authority, db, runner


def _admissions(db, authority, job_id, fire):
    from persistence.authority.bindings import cron_request_id, local_session_id
    from persistence.authority.vocabulary import CRON_PRINCIPAL_ID
    sid = local_session_id(authority.profile_id, CRON_PRINCIPAL_ID, cron_request_id(job_id, fire))
    return sid, db.admissions.list(session_id=sid, pending_only=False)


def _finish_run(db, authority, sid, outcome='completed', cron_result=(True, 'document', 'answer', None)):
    row = db.admissions.claim(epoch=authority.epoch, session_id=sid)
    db.admissions.settle(epoch=authority.epoch, admission_id=row.admission_id, generation=row.generation, outcome=outcome,
                         result={'result': {'cron_result': list(cron_result)}, 'usage': {}})


def _fire(job, fire):
    return scheduler._run_one_job_body(dict(jobs.get_job(job['id']), execution_id=fire))


def _outputs(job_id):
    folder = jobs._job_output_dir(job_id)
    return [p.read_text() for p in sorted(folder.glob('*.md'))] if folder.exists() else []


def _age_journal(job_id, fire, minutes):
    journal = scheduler_authority.journal_path(job_id, fire)
    record = json.loads(journal.read_text())
    since = (hermes_now() - timedelta(minutes=minutes)).isoformat()
    record['deferred'] = dict(record.get('deferred') or {}, since=since)
    journal.write_text(json.dumps(record))
    return record


def test_drain_refusal_defers_then_replays_once_after_the_drain(tmp_path, monkeypatch):
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        authority, db, runner = _owner(tmp_path, monkeypatch)
        fire = executions.create_execution(job['id'], source='test')['id']

        async def probe():
            session_cron.bind_owner(authority)
            try:
                runner._draining = True
                await asyncio.to_thread(_fire, job, fire)
                row = executions.get_execution(fire)
                assert row['status'] not in ('failed', 'completed'), row
                assert jobs.get_job(job['id']).get('last_status') in (None, 'pending'), jobs.get_job(job['id'])
                assert jobs.get_job(job['id'])['state'] != 'paused'
                assert scheduler_authority.journal_path(job['id'], fire).exists()
                sid, rows = _admissions(db, authority, job['id'], fire)
                assert rows == []

                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                assert _admissions(db, authority, job['id'], fire)[1] == []
                assert scheduler_authority.journal_path(job['id'], fire).exists()

                runner._draining = False
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                sid, rows = _admissions(db, authority, job['id'], fire)
                assert len(rows) == 1 and rows[0].status == 'queued'

                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                assert len(_admissions(db, authority, job['id'], fire)[1]) == 1

                _finish_run(db, authority, sid)
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                assert executions.get_execution(fire)['status'] == 'completed'
                assert not scheduler_authority.journal_path(job['id'], fire).exists()
                completed = jobs.get_job(job['id'])['repeat']['completed']
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                assert jobs.get_job(job['id'])['repeat']['completed'] == completed
                assert len(_admissions(db, authority, job['id'], fire)[1]) == 1
                assert [r for r in executions.list_executions(job_id=job['id']) if r['id'] == fire] and len(
                    executions.list_executions(job_id=job['id'])) == 1
            finally:
                session_cron.unbind_owner(authority)
        try:
            asyncio.run(probe())
        finally:
            db.close()


def test_drain_longer_than_the_bound_settles_skipped_with_a_visible_line(tmp_path, monkeypatch):
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        authority, db, runner = _owner(tmp_path, monkeypatch)
        fire = executions.create_execution(job['id'], source='test', scheduled_instant=hermes_now().isoformat())['id']

        async def probe():
            session_cron.bind_owner(authority)
            try:
                runner._draining = True
                await asyncio.to_thread(_fire, job, fire)
                _age_journal(job['id'], fire, MAX_DEFER_MINUTES + 1)
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
            finally:
                session_cron.unbind_owner(authority)
            row = executions.get_execution(fire)
            assert row['status'] == 'failed'
            assert row['error'].lower().startswith('skipped') and 'gateway was draining' in row['error']
            assert not scheduler_authority.journal_path(job['id'], fire).exists()
            assert _admissions(db, authority, job['id'], fire)[1] == []
            assert jobs.get_job(job['id'])['last_status'] != 'ok'
            record = '\n'.join(_outputs(job['id']))
            assert fire in record and 'gateway was draining' in record and 'skipped' in record.lower()
        try:
            asyncio.run(probe())
        finally:
            db.close()


def test_crash_between_the_journal_and_the_submit_is_resubmitted_on_the_next_scan(tmp_path, monkeypatch):
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        authority, db, _runner = _owner(tmp_path, monkeypatch)
        fire = executions.create_execution(job['id'], source='test')['id']
        params = {'job_id': job['id'], 'request_id': fire, 'extra_prompt': None}
        journal = scheduler_authority.journal_path(job['id'], fire)
        journal.parent.mkdir(parents=True, exist_ok=True)
        journal.write_text(json.dumps({'params': params, 'receipt': None}))
        executions.give_up_execution(fire, reason='firer lost')

        async def probe():
            session_cron.bind_owner(authority)
            try:
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                sid, rows = _admissions(db, authority, job['id'], fire)
                assert len(rows) == 1
                assert executions.get_execution(fire)['status'] == 'unknown'
                _finish_run(db, authority, sid)
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
                assert executions.get_execution(fire)['status'] == 'completed'
                assert len(_admissions(db, authority, job['id'], fire)[1]) == 1
            finally:
                session_cron.unbind_owner(authority)
        try:
            asyncio.run(probe())
        finally:
            db.close()


def test_restart_before_the_run_starts_keeps_the_admission_for_the_next_owner(tmp_path, monkeypatch):
    from gateway.session_unattended_unknown import settle_recovered_unattended
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        authority, db, _runner = _owner(tmp_path, monkeypatch)

        async def probe():
            params = {'job_id': job['id'], 'request_id': 'fire', 'extra_prompt': None}
            await session_cron.operation(authority, 'submit', params)
            authority.epoch = db.runtime.begin_epoch(instance_id='restart')
            db.admissions.recover(epoch=authority.epoch)
            assert settle_recovered_unattended(db, authority.epoch) == 0
            rows = _admissions(db, authority, job['id'], 'fire')[1]
            assert [r.status for r in rows] == ['queued']
        try:
            asyncio.run(probe())
        finally:
            db.close()


def test_restart_after_the_run_started_is_not_rerun_and_leaves_a_visible_record(tmp_path, monkeypatch):
    from gateway.session_unattended_unknown import settle_recovered_unattended
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        authority, db, _runner = _owner(tmp_path, monkeypatch)
        fire = executions.create_execution(job['id'], source='test', scheduled_instant=hermes_now().isoformat())['id']
        executions.give_up_execution(fire, reason='gateway restarted')

        async def probe():
            params = {'job_id': job['id'], 'request_id': fire, 'extra_prompt': None}
            receipt = await session_cron.operation(authority, 'submit', params)
            db.admissions.claim(epoch=authority.epoch, session_id=receipt['session_id'])
            journal = scheduler_authority.journal_path(job['id'], fire)
            journal.parent.mkdir(parents=True, exist_ok=True)
            journal.write_text(json.dumps({'params': params, 'receipt': None}))
            authority.epoch = db.runtime.begin_epoch(instance_id='restart')
            db.admissions.recover(epoch=authority.epoch)
            assert settle_recovered_unattended(db, authority.epoch) == 1
            session_cron.bind_owner(authority)
            try:
                await asyncio.to_thread(scheduler_authority.reconcile_pending)
            finally:
                session_cron.unbind_owner(authority)
            assert len(_admissions(db, authority, job['id'], fire)[1]) == 1
            row = executions.get_execution(fire)
            assert row['status'] == 'failed' and 'gateway restart' in row['error'] and 'not run again' in row['error']
            record = '\n'.join(_outputs(job['id']))
            assert fire in record and 'not run again' in record
        try:
            asyncio.run(probe())
        finally:
            db.close()


def test_unattended_failed_turn_never_tells_nobody_to_send_it_again():
    from agent import conversation_loop
    from agent.turn_failure_copy import AUTOMATION_INTERRUPTED_NOTICE, FAILED_TURN_NOTICE, PARTIAL_FAILED_TURN_NOTICE

    class Store:
        def latest_conversation_role(self, session_id):
            return 'user'

    def close(platform):
        messages = [{'role': 'user', 'content': 'report'}]
        flushed = []
        agent = SimpleNamespace(platform=platform, _session_db=Store(), session_id='s', _persist_disabled=False,
                                _flush_messages_to_session_db=flushed.append)
        conversation_loop._close_durable_failed_turn(agent, {'messages': messages, 'completed': False, 'failed': True})
        return messages[-1]['content']

    assert close('cron') == AUTOMATION_INTERRUPTED_NOTICE
    assert close('cli') == FAILED_TURN_NOTICE
    assert PARTIAL_FAILED_TURN_NOTICE != AUTOMATION_INTERRUPTED_NOTICE


def test_update_pause_before_the_connection_defers_the_run_and_a_ready_owner_takes_it(tmp_path, monkeypatch):
    with jobs.use_cron_store(tmp_path / 'cron'):
        job = jobs.create_job(prompt='report', schedule='every 1h', deliver='local')
        fire = executions.create_execution(job['id'], source='test')['id']
        ready = False
        calls = []

        class Peer:
            async def rpc(self, method, **params):
                calls.append(method)
                if method == 'cron.recover':
                    return {'status': 'missing', 'result': None}
                return {'session_id': 's', 'admission_id': 'a'}

        @asynccontextmanager
        async def connected():
            if not ready:
                raise gateway_client.GatewayUnavailableError('Gateway draining: update_paused', 'draining', 'update_paused')
            yield Peer()
        monkeypatch.setattr(gateway_client, 'connect_gateway', connected)

        _fire(job, fire)
        assert executions.get_execution(fire)['status'] not in ('failed', 'completed')
        assert jobs.get_job(job['id'])['state'] != 'paused'
        journal = scheduler_authority.journal_path(job['id'], fire)
        assert json.loads(journal.read_text())['deferred']['reason'] == 'runtime_draining'

        scheduler_authority.reconcile_pending()
        assert journal.exists() and 'cron.submit' not in calls

        ready = True
        scheduler_authority.reconcile_pending()
        assert calls.count('cron.submit') == 1
        assert json.loads(journal.read_text())['receipt'] == {'session_id': 's', 'admission_id': 'a'}
