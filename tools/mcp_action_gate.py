"""Default-deny action gate for MCP servers whose config carries an ``action_policy``.

A tool is READ only when its exact name is on the server's read list, REFUSED when it names a step the
policy never allows (money), and an ACTION otherwise, so an unknown tool asks. An ACTION runs only after
the owner approves the exact call on a card in their own app, and the approval is bound to a digest of the
arguments it was shown for. Nothing here consults tool output, yolo, or any remembered answer.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import threading
import unicodedata
from dataclasses import dataclass
from typing import Any, Mapping, Optional

from tools.registry import tool_error

logger = logging.getLogger("tools.mcp_action_gate")

READ, ACTION, REFUSED = "read", "action", "refused"

APPROVAL_UNAVAILABLE = "approval_unavailable"
ACTION_DENIED = "action_denied"
ACTION_REFUSED = "action_refused"
APPROVAL_MISMATCH = "approval_mismatch"
GATE_FAILED = "action_gate_failed"

_DEFAULT_REFUSED_MESSAGE = "This step moves money, so it is not done through the assistant. Do it yourself on the service's website."
_TOKEN_RE = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+")
_RECIPIENT_KEYS = ("recipient", "to", "freelancer", "freelancer_id", "client", "user_id", "room_id", "job_id", "job")
_TEXT_KEYS = ("cover_letter", "message", "body", "text", "content", "proposal", "description")
_FIELD_VALUE_MAX_CHARS = 600
_MAX_FIELDS = 24


def _tokens(name: str) -> frozenset[str]:
    return frozenset(t.lower()[:-1] if len(t) > 3 and t.lower().endswith("s") else t.lower()
                     for t in _TOKEN_RE.findall(name))


@dataclass(frozen=True)
class ActionPolicy:
    read_tools: frozenset[str]
    refused_patterns: tuple[frozenset[str], ...]
    refused_message: str

    @classmethod
    def from_config(cls, raw: Any) -> ActionPolicy:
        """Malformed input degrades to the strictest policy (nothing readable, no refused list), never to none."""
        raw = raw if isinstance(raw, Mapping) else {}

        def strings(key: str) -> list[str]:
            value = raw.get(key)
            return [item for item in value if isinstance(item, str) and item] if isinstance(value, list) else []

        message = raw.get("refused_message")
        return cls(read_tools=frozenset(strings("read_tools")),
                   refused_patterns=tuple(p for p in (_tokens(name) for name in strings("refused_tools")) if p),
                   refused_message=message.strip() if isinstance(message, str) and message.strip()
                   else _DEFAULT_REFUSED_MESSAGE)

    def classify(self, tool_name: str) -> str:
        tokens = _tokens(tool_name)
        if any(pattern <= tokens for pattern in self.refused_patterns):
            return REFUSED
        return READ if tool_name in self.read_tools else ACTION


def policy_from_config(config: Any) -> Optional[ActionPolicy]:
    if not isinstance(config, Mapping) or "action_policy" not in config:
        return None
    return ActionPolicy.from_config(config["action_policy"])


def call_digest(server_name: str, tool_name: str, args: Optional[Mapping]) -> str:
    canonical = json.dumps({"server": server_name, "tool": tool_name, "args": dict(args or {})},
                           sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class ActionGrant:
    """One approval for one exact call. ``consume`` is the only way through: it spends the grant on the
    first attempt, match or not, and refuses a call whose arguments differ from the ones approved."""

    __slots__ = ("_digest", "_lock", "_spent")

    def __init__(self, digest: str):
        self._digest, self._spent, self._lock = digest, False, threading.Lock()

    def consume(self, server_name: str, tool_name: str, args: Optional[Mapping]) -> Optional[str]:
        with self._lock:
            if self._spent:
                return tool_error("This approval was already used. Ask again for a new one.", code=APPROVAL_MISMATCH)
            self._spent = True
        try:
            matches = call_digest(server_name, tool_name, args) == self._digest
        except (TypeError, ValueError):
            matches = False
        if not matches:
            return tool_error("The call changed after the owner approved it, so it was not run.",
                              code=APPROVAL_MISMATCH)
        return None

    def refund(self) -> None:
        with self._lock:
            self._spent = True


_auto_lock = threading.Lock()
_auto_approved: set[tuple[str, str]] = set()


def set_auto_approve(session_key: str, server_name: str, enabled: bool) -> None:
    with _auto_lock:
        (_auto_approved.add if enabled else _auto_approved.discard)((session_key, server_name))


def auto_approve_enabled(session_key: str, server_name: str) -> bool:
    with _auto_lock:
        return (session_key, server_name) in _auto_approved


def clear_session(session_key: str) -> None:
    with _auto_lock:
        for entry in [e for e in _auto_approved if e[0] == session_key]:
            _auto_approved.discard(entry)


def _safe_text(value: Any, limit: int = _FIELD_VALUE_MAX_CHARS) -> str:
    from agent.redact import redact_sensitive_text
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    text = "".join(ch.encode("unicode_escape").decode() if ch != "\n" and unicodedata.category(ch) in ("Cc", "Cf")
                   else ch for ch in text[:limit * 4])
    text = redact_sensitive_text(text, force=True)
    return text if len(text) <= limit else text[:limit].rstrip() + "..."


def _first_value(args: Mapping, keys: tuple[str, ...]) -> str:
    for key in keys:
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            return _safe_text(value)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return str(value)
    return ""


def build_card(server_name: str, tool_name: str, args: Mapping) -> dict:
    """The approval card, built from the call alone. Tool output never reaches it."""
    from tools.bot_mode_drafts import DRAFT_KIND
    from tools.mcp_tool_handlers import _mask_secret_fields
    shown = _mask_secret_fields(dict(args))
    details = [{"name": _safe_text(str(name), 80), "value": _safe_text(value)}
               for name, value in list(shown.items())[:_MAX_FIELDS]]
    if len(shown) > _MAX_FIELDS:
        details.append({"name": "more", "value": f"{len(shown) - _MAX_FIELDS} more fields not shown"})
    text = _first_value(shown, _TEXT_KEYS) or "\n".join(f"{d['name']}: {d['value']}" for d in details) or tool_name
    recipient = _first_value(shown, _RECIPIENT_KEYS)
    draft = {"kind": DRAFT_KIND, "channel": server_name, "recipient": recipient, "subject": tool_name,
             "text": text, "editable": False, "held": False}
    return {"text": text, "draft": draft, "details": details,
            "description": f"Run '{tool_name}' on {server_name} once with exactly the details shown, or deny."}


def _approve(server_name: str, tool_name: str, args: Mapping) -> Optional[str]:
    from tools import approval
    card = build_card(server_name, tool_name, args)
    result = approval.request_draft_approval(
        text=card["text"], description=card["description"], pattern_key=f"mcp_action:{server_name}/{tool_name}",
        draft=card["draft"], details=card["details"])
    if result.get("approved") is True:
        return None
    logger.info("MCP action not approved: server=%s tool=%s outcome=%s", server_name, tool_name,
                result.get("outcome") or "denied")
    return tool_error(f"The owner did not approve '{tool_name}'. It was NOT run. Do not retry without a new "
                      f"request from the owner.", code=ACTION_DENIED)


def approver_present() -> bool:
    """True only on a turn the owner's own app submitted, with that app attached and able to answer. A delegated
    child, a cron or single-query run and a finite one-shot turn never qualify, even inside such a chat."""
    from agent.delegation_context import is_delegated_child_context
    from tools import approval_context
    return (not is_delegated_child_context() and not approval_context._no_user_can_answer()
            and approval_context.is_viewer_turn_with_approver())


def _gate(policy: ActionPolicy, server_name: str, tool_name: str,
          args: Optional[Mapping]) -> tuple[Optional[str], Optional[ActionGrant]]:
    kind = policy.classify(tool_name)
    if kind == READ:
        return None, None
    if kind == REFUSED:
        return tool_error(policy.refused_message, code=ACTION_REFUSED), None
    from tools.approval_context import get_current_session_key
    if not approver_present():
        return tool_error(f"'{tool_name}' changes things on {server_name}, so it needs the owner's approval in "
                          f"their app, and nobody can approve in this chat. It was NOT run.",
                          code=APPROVAL_UNAVAILABLE), None
    args = dict(args or {})
    grant = ActionGrant(call_digest(server_name, tool_name, args))
    session_key = get_current_session_key(default="")
    if session_key and auto_approve_enabled(session_key, server_name):
        logger.info("MCP action auto-approved: server=%s tool=%s", server_name, tool_name)
        return None, grant
    refusal = _approve(server_name, tool_name, args)
    return (refusal, None) if refusal else (None, grant)


def gate(policy: ActionPolicy, server_name: str, tool_name: str,
         args: Optional[Mapping]) -> tuple[Optional[str], Optional[ActionGrant]]:
    """``(error, None)`` blocks the call, ``(None, grant)`` lets one exact call through once, ``(None, None)``
    is a read. Any failure blocks."""
    try:
        return _gate(policy, server_name, tool_name, args)
    except Exception as exc:  # health: allow BLE001 -- fail closed on any error; only the exception type is logged so call arguments never reach a log
        logger.error("MCP action gate failed for %s/%s (%s); call blocked", server_name, tool_name,
                     type(exc).__name__)
        return tool_error(f"'{tool_name}' was blocked because the approval check failed.", code=GATE_FAILED), None
