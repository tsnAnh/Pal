import asyncio
import time
from dataclasses import dataclass
from functools import partial
from typing import Literal, Optional

from gateway import send_stats
from gateway.session_persistence import authority_persistence
from gateway.session_queued_controls import (
    _deliver, _latch, _receiving_agent, _register, _unregister, steer_blocker,
)
from persistence.authority.vocabulary import STEERING
from persistence.core.errors import AuthorityRefusal
from tools.interrupt import YieldReason

Outcome = Literal['absorbed', 'idle', 'no_agent', 'missed']


@dataclass(frozen=True)
class Transfer:
    outcome: Outcome
    committed: Optional[dict] = None


def _admission(authority, admission_id) -> Optional[dict]:
    from gateway.session_authority import admission_row
    return admission_row(authority_persistence(authority).admissions.get(admission_id=admission_id))


def is_owner_input(payload) -> bool:
    return 'local_operator_v1' not in payload and not (payload.get('turn_author') or {}).get('is_bot')


async def is_bot_chat(authority, session_id) -> bool:
    from tools.bot_mode_probe import BOT_CHAT_TITLE, is_bot_mode_managed
    store = authority_persistence(authority)
    if store.sessions.get_title(session_id) != BOT_CHAT_TITLE:
        return False
    return await asyncio.to_thread(is_bot_mode_managed, store.scope.profile_dir)


async def absorb_into_running_turn(authority, ref, admission_id, *, reason: Optional[YieldReason],
                                   latch: bool = False) -> Transfer:
    handle = authority._handle(ref)
    if handle.execution_state != 'running':
        return Transfer('idle')
    session_id, generation = ref.session_id, handle.execution_generation
    text = _admission(authority, admission_id)['payload']['text']
    live = authority.sessions[session_id]
    with live.event_stream.lock:
        agent = _receiving_agent(authority, session_id, generation)
        if agent is None and not (latch and _awaiting_agent(authority, ref, generation)):
            return Transfer('no_agent')
        _register(authority, session_id, generation, admission_id)
    from gateway.session_authority import admission_row
    from gateway.session_runtime_workers import tracked_write
    admissions = authority_persistence(authority).admissions
    try:
        committed, fresh = await tracked_write(authority, partial(
            admissions.steer, epoch=authority.epoch, admission_id=admission_id, generation=generation))
    except AuthorityRefusal:
        with live.event_stream.lock:
            _unregister(authority, session_id, generation, admission_id)
        raise
    if fresh:
        with live.event_stream.lock:
            agent = agent or _receiving_agent(authority, session_id, generation)
            if agent is not None:
                delivered = _deliver(authority, session_id, generation, agent, admission_id, text, reason)
            else:
                delivered = _awaiting_agent(authority, ref, generation)
                if delivered:
                    _latch(authority, session_id, generation, admission_id, text)
        if not delivered:
            await tracked_write(authority, partial(admissions.revert_steer, epoch=authority.epoch,
                                                   admission_id=admission_id, generation=generation))
            with live.event_stream.lock:
                _unregister(authority, session_id, generation, admission_id)
            authority._publish_pending(ref)
            authority._schedule(ref)
            return Transfer('missed')
        authority._publish_pending(ref)
    return Transfer('absorbed', admission_row(committed))


def _awaiting_agent(authority, ref, generation) -> bool:
    from gateway.session_busy_controls import adopts_owner_agent
    return (authority.executing.get(ref.session_id) == generation
            and authority.adopted.get(ref.session_id, (None, None))[0] != generation
            and adopts_owner_agent(authority, ref))


async def absorb_owner_input(authority, ref, admission_id, payload) -> Optional[str]:
    started = time.monotonic()
    status, why = await _absorb_owner_input(authority, ref, admission_id, payload)
    await asyncio.to_thread(send_stats.admitted, admission_id, status, why, (time.monotonic() - started) * 1000)
    return status


def _queued_ahead(authority, ref, row) -> bool:
    return any(waiting.status == 'queued' and waiting.seq < row['seq']
               for waiting in authority_persistence(authority).admissions.list(session_id=ref.session_id))


async def _absorb_owner_input(authority, ref, admission_id, payload) -> tuple[Optional[str], str]:
    """``(status, why)``: the disposition ``prompt.submit`` reports and the gate that decided it."""
    if not is_owner_input(payload):
        return None, 'operator'
    if not await is_bot_chat(authority, ref.session_id):
        return None, 'not_bot_chat'
    row = _admission(authority, admission_id)
    if row['status'] != 'queued':
        return ('steered' if row['outcome'] in (STEERING, 'steered') else 'turn'), 'not_queued'
    state = authority._handle(ref).execution_state
    if state != 'running':
        return ('turn' if state == 'idle' else 'queued'), state
    if (blocker := steer_blocker(authority, row, any_source=True)) is not None:
        return 'queued', f'not_steerable:{blocker}'
    if await asyncio.to_thread(_queued_ahead, authority, ref, row):
        return 'queued', 'behind_queue'
    try:
        transfer = await absorb_into_running_turn(authority, ref, admission_id, reason=YieldReason.OWNER_MESSAGE,
                                                  latch=True)
    except AuthorityRefusal as refusal:
        return 'queued', refusal.reason
    return ('steered' if transfer.outcome == 'absorbed' else 'queued'), transfer.outcome
