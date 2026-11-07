from __future__ import annotations

import logging
import sqlite3
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from tools.bot_thread_ledger import ExchangeKey

logger = logging.getLogger(__name__)


def peer_origin() -> Optional[str]:
    from agent.turn_author import local_origin
    return local_origin() or None


@dataclass(frozen=True, slots=True)
class DirectPeerExchange:
    home: Path
    key: ExchangeKey

    def settle(self, result: Any) -> None:
        from gateway.response_filters import is_intentional_silence_response, strip_trailing_silence_marker
        from tools.bot_failure_reasons import classify_agent_error
        from tools.bot_thread_ledger import Outcome, record_outcome
        if not isinstance(result, dict) or result.get("failed"):
            error = str(result.get("error") or "") if isinstance(result, dict) else ""
            record_outcome(self.home, self.key, Outcome.failed(classify_agent_error(error) if error else ""))
            return
        reply = str(result.get("final_response") or "")
        reply = "" if is_intentional_silence_response(reply) else strip_trailing_silence_marker(reply)
        record_outcome(self.home, self.key, Outcome.answered(reply))


def open_direct_peer_exchange(db: Any, session_id: str, message: str, author: Any) -> Optional[DirectPeerExchange]:
    from tools.bot_dm_wire import split_sender_stamp
    from tools.bot_relay import read_remote_roster
    from tools.bot_thread_identity import inbound
    from tools.bot_thread_ledger import Direction, Status, record_message
    if db is None:
        return None
    try:
        bot_chat = db.get_session_by_title("Bot Chat")
        if bot_chat is None or db.get_compression_tip(bot_chat["id"]) != db.get_compression_tip(session_id):
            return None
    except sqlite3.Error:
        logger.warning("bot thread ledger could not resolve the Bot Chat for a peer turn", exc_info=True)
        return None
    home = Path(db.db_path).parent
    stamp = split_sender_stamp(message)
    counterpart = inbound(author, stamp, read_remote_roster(home))
    key = ExchangeKey.of(Direction.inbound, uuid.uuid4().hex)
    if counterpart is None or key is None:
        return None
    record_message(home, key, counterpart, stamp.body if stamp else message, status=Status.delivered)
    return DirectPeerExchange(home, key)


async def run_session_chat_turn(adapter: Any, ctx: dict) -> tuple[Any, Any]:
    from tools.bot_failure_reasons import RETRY_NONE, result_retry_action
    session_id = ctx["session_id"]
    exchange = open_direct_peer_exchange(await adapter._ensure_session_db_async(), session_id, ctx["user_message"],
                                         ctx["run_kwargs"].get("turn_author"))
    history = await adapter._conversation_history_for_session(session_id)
    result, usage = await adapter._run_agent(conversation_history=history, **ctx["run_kwargs"])
    # One policy-gated re-run of a transiently failed turn — the peer-DM transport's half of the
    # retry the local (``tools.bot_mode_dm``) and relayed (``tui_gateway.methods_bot_relay``)
    # delivery lanes already apply (#93091 item 5, #115325). Same policy, same gate: transient
    # classes (429 / 5xx) re-run the SAME session once, a context overflow lets the re-run's
    # pre-API compaction shrink the transcript first, and auth/quota/config/model never re-run. The
    # store is read again first: the failed attempt's turn-start persist left the DM as the
    # transcript's unanswered tail row, and the re-run resumes that row instead of appending a
    # second copy of it. A turn that fails again reaches the peer client exactly as before.
    if result_retry_action(result) != RETRY_NONE:
        history = await adapter._conversation_history_for_session(session_id)
        result, usage = await adapter._run_agent(
            conversation_history=history, resume_unanswered_turn=True, **ctx["run_kwargs"])
    if exchange is not None:
        exchange.settle(result)
    return result, usage
