import asyncio
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import Literal, Optional

from gateway.session_queued_controls import (
    _deliver, _receiving_agent, _register, _unregister, queued_controls,
)
from hermes_state_runtime import (
    STEERING, RuntimeStoreError, get_session_admission, revert_steer_input, steer_session_input,
)
from tools.interrupt import YieldReason

Outcome = Literal['absorbed', 'idle', 'no_agent', 'missed']


@dataclass(frozen=True)
class Transfer:
    outcome: Outcome
    committed: Optional[dict] = None


async def is_bot_chat(authority, session_id) -> bool:
    from tools.bot_mode_probe import BOT_CHAT_TITLE, is_bot_mode_managed
    if authority.db.get_session_title(session_id) != BOT_CHAT_TITLE:
        return False
    return await asyncio.to_thread(is_bot_mode_managed, Path(authority.db.db_path).parent)


async def absorb_into_running_turn(authority, ref, admission_id, *, reason: Optional[YieldReason]) -> Transfer:
    handle = authority._handle(ref)
    if handle.execution_state != 'running':
        return Transfer('idle')
    session_id, generation = ref.session_id, handle.execution_generation
    text = get_session_admission(authority.db, admission_id=admission_id)['payload']['text']
    live = authority.sessions[session_id]
    with live.event_stream.lock:
        agent = _receiving_agent(authority, session_id, generation)
        if agent is None:
            return Transfer('no_agent')
        _register(authority, session_id, generation, admission_id)
    from gateway.session_runtime_workers import tracked_write
    try:
        committed, fresh = await tracked_write(authority, partial(
            steer_session_input, authority.db, epoch=authority.epoch, admission_id=admission_id, generation=generation))
    except RuntimeStoreError:
        with live.event_stream.lock:
            _unregister(authority, session_id, generation, admission_id)
        raise
    if fresh:
        with live.event_stream.lock:
            delivered = _deliver(authority, session_id, generation, agent, admission_id, text, reason)
        if not delivered:
            await tracked_write(authority, partial(revert_steer_input, authority.db, epoch=authority.epoch,
                                                   admission_id=admission_id, generation=generation))
            with live.event_stream.lock:
                _unregister(authority, session_id, generation, admission_id)
            authority._publish_pending(ref)
            authority._schedule(ref)
            return Transfer('missed')
        authority._publish_pending(ref)
    return Transfer('absorbed', committed)


async def absorb_owner_input(authority, ref, admission_id, payload) -> Optional[str]:
    if 'local_operator_v1' in payload or (payload.get('turn_author') or {}).get('is_bot'):
        return None
    if not await is_bot_chat(authority, ref.session_id):
        return None
    row = get_session_admission(authority.db, admission_id=admission_id)
    if row['status'] != 'queued':
        return 'steered' if row['outcome'] in (STEERING, 'steered') else 'turn'
    state = authority._handle(ref).execution_state
    if state != 'running':
        return 'turn' if state == 'idle' else 'queued'
    if 'steer' not in queued_controls(authority, row):
        return 'queued'
    try:
        transfer = await absorb_into_running_turn(authority, ref, admission_id, reason=YieldReason.OWNER_MESSAGE)
    except RuntimeStoreError:
        return 'queued'
    return 'steered' if transfer.outcome == 'absorbed' else 'queued'
