"""Explicit Stop of one Bot Chat delivery: the turn it started, and the deliveries that turn handed on.

``interrupt`` alone leaves background work alive on purpose; this is the ``/stop`` family, so the
target session's background processes and async delegations end with its turn.
"""
import asyncio
import logging

from gateway.session_bot import _home
from gateway.session_bot_mailbox import read_receipt
from gateway.session_contract import SessionRef
from hermes_state_runtime import RuntimeStoreError, get_session_admission
from tools.bot_live_delivery import _delivery_id

logger = logging.getLogger(__name__)


async def stop_delivery(connection, params):
    authority, actor = connection.authority, connection.actor
    if set(params) - {'id', 'profile'}:
        raise RuntimeStoreError('invalid_params')
    home = _home(authority, actor, params.get('profile'))
    if 'session:control' not in actor.capabilities:
        raise RuntimeStoreError('permission_denied')
    try:
        key = _delivery_id(params.get('id'))
    except ValueError as exc:
        raise RuntimeStoreError('invalid_params') from exc
    _, record = await read_receipt(home, key)
    admission_id = (record or {}).get('admission_id')
    if not admission_id:
        return {'status': 'not_found', 'stopped': False, 'handoffs': 0}
    ref = SessionRef(authority.profile_id, record['session_id'])
    outcome, handoffs = await _stop_admission(connection, ref, admission_id)
    return {'status': outcome, 'stopped': outcome in {'cancelled', 'interrupted'}, 'handoffs': handoffs}


async def _stop_admission(connection, ref, admission_id):
    authority, actor = connection.authority, connection.actor
    row = get_session_admission(authority.db, admission_id=admission_id)
    if row is None or row['status'] == 'terminal':
        return 'finished', 0
    if row['status'] == 'queued':
        row = await authority.cancel_or_claimed(actor, ref, admission_id)
        if row is None:
            return 'cancelled', 0
    if row['status'] != 'started':
        return 'finished', 0
    await authority.interrupt(actor, ref, row['generation'])
    from gateway.session_ancillary import stop_processes
    try:
        return 'interrupted', (await stop_processes(connection, ref, {'session_id': ref.session_id}))['handoffs']
    except RuntimeStoreError as exc:
        logger.info('Bot Chat stop left background work of %s running (%s)', ref.session_id, exc.reason)
        return 'interrupted', 0


async def stop_handed_on(authority, ref):
    """Stop every delivery the session ``ref`` handed to another Bot Chat, and what those turns handed on."""
    from gateway.session_ancillary import physical_target
    from tools.bot_handoff_ledger import take_handoffs
    from tools.bot_live_delivery import authority_stop
    stopped = 0
    for handoff in take_handoffs({ref.session_id, physical_target(authority, ref)}):
        try:
            await asyncio.to_thread(
                authority_stop, handoff['profile_home'], {'id': handoff['delivery_id'], 'profile': handoff['profile']})
            stopped += 1
        except Exception:
            logger.warning('stopping handed-on delivery %s failed', handoff['delivery_id'], exc_info=True)
    return stopped
