"""Owner approval for tools called from an owner-lane turn that no human typed.

An ask-reply wake, an owner-approved hand-off and any other internal turn whose input carries someone else's
words run in the owner's lane with the owner's reach. Outside ``UNTRUSTED_SENDER_SAFE_TOOLS`` and
``CONVERSATION_BOUND_TOOLS`` (which refuse any target beyond the turn's own conversation themselves) every call there
needs the owner to approve that exact call on a card in their own direct messages. yolo, session and permanent
grants are never consulted. Ordinary owner turns pass straight through.
"""

from __future__ import annotations

import contextlib
import contextvars
import logging
import threading
from collections.abc import Iterator, Mapping
from typing import Any, Optional

from tools.registry import tool_error

logger = logging.getLogger(__name__)

GATE_SERVER = "hermes"
OWNER_DENIED = "owner_denied"
GATE_FAILED = "owner_gate_failed"
OWNER_UNREACHABLE = "owner_unreachable"


class CallGrant:
    __slots__ = ("_digest", "_lock", "_spent", "tool_name")

    def __init__(self, tool_name: str, args: Optional[Mapping]) -> None:
        from tools.mcp_action_gate import call_digest
        self.tool_name = tool_name
        self._digest = call_digest(GATE_SERVER, tool_name, args)
        self._lock = threading.Lock()
        self._spent = False

    def spend(self, tool_name: str, args: Optional[Mapping] = None, *, prefix: bool = False) -> bool:
        from tools.mcp_action_gate import call_digest
        named = self.tool_name.startswith(tool_name) if prefix else self.tool_name == tool_name
        try:
            exact = args is None or call_digest(GATE_SERVER, tool_name, args) == self._digest
        except (TypeError, ValueError):
            exact = False
        if not named or not exact:
            return False
        with self._lock:
            if self._spent:
                return False
            self._spent = True
            return True


_bound: contextvars.ContextVar[Optional[CallGrant]] = contextvars.ContextVar("owner_call_grant", default=None)


@contextlib.contextmanager
def bound_call_grant(grant: Optional[CallGrant]) -> Iterator[None]:
    token = _bound.set(grant)
    try:
        yield
    finally:
        _bound.reset(token)


def spend_call_grant(tool_name: str, args: Optional[Mapping] = None, *, prefix: bool = False) -> bool:
    grant = _bound.get()
    return grant is not None and grant.spend(tool_name, args, prefix=prefix)


def _owner_approves(tool_name: str, args: Mapping) -> Optional[str]:
    from tools import approval
    from tools.mcp_action_gate import build_card
    card = build_card(GATE_SERVER, tool_name, args)
    result = approval.request_draft_approval(
        text=card["text"], pattern_key=f"owner_call:{tool_name}", draft=card["draft"], details=card["details"],
        description=f"Run '{tool_name}' once with exactly the details shown, or deny.")
    if result.get("approved") is True:
        return None
    logger.info("Owner did not approve a call from a turn carrying someone else's words: tool=%s outcome=%s",
                tool_name, result.get("outcome") or "denied")
    return tool_error(f"The owner did not approve '{tool_name}', so it was NOT run. Do not retry without a new "
                      f"request from the owner.", code=OWNER_DENIED)


def is_tainted_turn() -> bool:
    from gateway.session_context import current_turn_event
    event = current_turn_event()
    return event is not None and bool(event.internal) and bool(event.carries_member_content)


def admit_tainted_call(tool_name: str, args: Optional[Mapping]) -> tuple[Optional[str], Optional[CallGrant]]:
    if not is_tainted_turn():
        return None, None
    try:
        return _admit(tool_name, dict(args or {}))
    except Exception as exc:  # health: allow BLE001 -- fail closed on any error; only the exception type is logged so call arguments never reach a log
        logger.error("Owner approval gate failed for %s (%s); call blocked", tool_name, type(exc).__name__)
        return tool_error(f"'{tool_name}' was blocked because the approval check failed.", code=GATE_FAILED), None


def _admit(tool_name: str, args: dict[str, Any]) -> tuple[Optional[str], Optional[CallGrant]]:
    from gateway.audience.model import Audience
    from gateway.desk.owner import turn_facts
    from gateway.session_context import get_session_env
    from toolsets import CONVERSATION_BOUND_TOOLS, UNTRUSTED_SENDER_SAFE_TOOLS
    if tool_name in UNTRUSTED_SENDER_SAFE_TOOLS or tool_name in CONVERSATION_BOUND_TOOLS:
        return None, None
    facts = turn_facts(get_session_env("HERMES_SESSION_PLATFORM"))
    if facts is None:
        return tool_error(f"'{tool_name}' needs the owner's approval, and the owner can't be reached from here, "
                          f"so it was NOT run.", code=OWNER_UNREACHABLE), None
    if facts.audience is not Audience.OWNER:
        return None, None
    refusal = _owner_approves(tool_name, args)
    return (refusal, None) if refusal else (None, CallGrant(tool_name, args))
