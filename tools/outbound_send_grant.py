"""One owner pick approves one exact outbound send, once.

A clarify question may carry ``send`` (the exact call the bot will make and the option that sends it). When the
owner submits that option on the form that showed the call, ``tools.clarify_tool`` issues a grant here; the gates
that would ask a second time (``tools.bot_mode_drafts``, ``tools.mcp_action_gate``) redeem it when the real call has
the same tool and arguments. The model cannot issue one: only the clarify callback's reply does. A grant is bound to
the session and turn that asked, expires, and is spent by the first redeem. The digest and one-shot spend are
``tools.tainted_turn_gate.CallGrant``.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from tools.tainted_turn_gate import CallGrant

GRANT_TTL_SECONDS = 300
MAX_GRANTS_PER_SESSION = 16


@dataclass(frozen=True)
class _Entry:
    grant: CallGrant
    turn: Any
    expires: float


_lock = threading.Lock()
_entries: dict[str, list[_Entry]] = {}


def _identity() -> tuple[str, Any]:
    from gateway.session_context import current_turn_event
    from tools.approval_context import get_current_session_key
    return get_current_session_key(), current_turn_event()


def issue(tool_name: str, args: Mapping) -> None:
    session_key, turn = _identity()
    now = time.monotonic()
    entry = _Entry(CallGrant(tool_name, args), turn, now + GRANT_TTL_SECONDS)
    with _lock:
        live = [e for e in _entries.get(session_key, []) if e.expires > now]
        _entries[session_key] = [*live, entry][-MAX_GRANTS_PER_SESSION:]


def redeem(tool_name: str, args: Mapping) -> bool:
    session_key, turn = _identity()
    now = time.monotonic()
    with _lock:
        live = [e for e in _entries.get(session_key, []) if e.expires > now]
        redeemed = next((e for e in live if e.turn is turn and e.grant.spend(tool_name, args)), None)
        if redeemed is not None:
            live.remove(redeemed)
        if live:
            _entries[session_key] = live
        else:
            _entries.pop(session_key, None)
    return redeemed is not None


def clear_session(session_key: str) -> None:
    with _lock:
        _entries.pop(session_key, None)
