"""One owner pick approves one exact outbound send, once.

A clarify question may carry ``send`` (the exact call the bot will make and the option that sends it). When the
owner submits that option on the form that showed the call, ``tools.clarify_tool`` issues a grant here; the gates
that would ask a second time (``tools.bot_mode_drafts``, ``tools.mcp_action_gate``) redeem it when the real call has
the same tool and the same arguments after ``normalise``. The model cannot issue one: only the clarify callback's
reply does. A grant belongs to the session that asked, not to a turn, so it survives the turn that carries the
owner's answer; it expires and is spent by the first redeem. A call that differs only in fields that name neither
the recipient, the text, the subject nor an attachment redeems too: that call is the one the owner confirmed.
A tool whose name carries a send word passes both gates, so the first gate's spend leaves a short-lived pass for
the other gate of that same call. The digest and one-shot spend are ``tools.tainted_turn_gate.CallGrant``.
"""

from __future__ import annotations

import hashlib
import logging
import threading
import time
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Optional

from tools.tainted_turn_gate import CallGrant

logger = logging.getLogger(__name__)

GRANT_TTL_SECONDS = 300
GATE_PASS_TTL_SECONDS = 30
MAX_GRANTS_PER_SESSION = 16
DRAFT_GATE, MCP_GATE = "draft", "mcp"

_NESTED_KEYS = ("params",)
_ADDRESS_KEYS = frozenset({
    "to", "cc", "bcc", "recipient", "recipients", "recipient_email", "recipient_name", "email", "channel",
    "channel_id", "chat_id", "target", "user", "user_id", "room", "room_id", "room_title", "room_name", "thread",
    "thread_id", "conversation_id", "freelancer", "freelancer_id", "client", "job_id"})
_COPY_KEYS = frozenset({"subject", "title", "attachment", "attachments", "file", "files", "file_path", "file_paths",
                        "file_attachments", "media", "media_files", "image", "images", "document", "documents"})
_BODY_KEYS = ("message", "text", "body", "content", "markdown_text", "html_body", "plain_text", "html")
_DEPTH = 3
_DROPPED = object()


@dataclass(frozen=True)
class _Entry:
    grant: CallGrant
    tool: str
    args: dict
    signature: Optional[tuple]
    call_id: str
    expires: float


_lock = threading.Lock()
_entries: dict[str, list[_Entry]] = {}
_gate_passes: dict[str, list[_Entry]] = {}


def _clean(value: Any) -> Any:
    if value is None:
        return _DROPPED
    if isinstance(value, str):
        text = unicodedata.normalize("NFC", value).replace("\r\n", "\n").replace("\r", "\n").replace("\\n", "\n")
        text = "\n".join(line.rstrip() for line in text.split("\n")).strip()
        return text or _DROPPED
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else value
    if isinstance(value, Mapping):
        cleaned = {str(k).strip(): v for k, v in ((k, _clean(v)) for k, v in value.items()) if v is not _DROPPED}
        return cleaned or _DROPPED
    if isinstance(value, (list, tuple)):
        items = [v for v in map(_clean, value) if v is not _DROPPED]
        return items or _DROPPED
    return value


def normalise(tool_name: str, args: Optional[Mapping]) -> tuple[str, dict]:
    """The one form of a send call both the form's side and the gates' side are compared in: lowercase tool
    name, ``params`` merged into the top level, keys and values trimmed, empty values and ``None`` dropped, ids as
    text, line breaks as real ``\\n``."""
    cleaned = _clean(dict(args or {}))
    flat = {} if cleaned is _DROPPED else dict(cleaned)
    for key in _NESTED_KEYS:
        nested = flat.pop(key, None)
        if isinstance(nested, dict):
            flat = {**nested, **flat}
        elif nested is not None:
            flat[key] = nested
    return str(tool_name or "").strip().lower(), flat


def _collect(value: Any, keys: frozenset, depth: int = _DEPTH) -> list:
    found = []
    if isinstance(value, Mapping):
        for key, item in value.items():
            if str(key).lower() in keys:
                found.append((str(key).lower(), item))
            elif depth > 0:
                found += _collect(item, keys, depth - 1)
    return found


def _body_of(args: Mapping) -> Optional[str]:
    for key in _BODY_KEYS:
        if isinstance(args.get(key), str):
            return args[key]
    for item in args.values():
        if isinstance(item, Mapping) and (body := _body_of(item)) is not None:
            return body
    return None


def _signature(tool: str, args: Mapping) -> Optional[tuple]:
    body, address = _body_of(args), _collect(args, _ADDRESS_KEYS)
    if body is None or not address:
        return None
    pairs = lambda found: tuple(sorted((key, repr(value)) for key, value in found))
    return tool, body, pairs(address), pairs(_collect(args, _COPY_KEYS))


def _fingerprint(session_key: str) -> str:
    return hashlib.sha256(session_key.encode("utf-8")).hexdigest()[:10]


def _identity() -> tuple[str, str]:
    from tools.approval_context import get_current_session_key, get_current_tool_call_id
    return get_current_session_key(), get_current_tool_call_id()


def _log(event: str, tool: str, session_key: str, **fields: str) -> None:
    extras = "".join(f" {name}={value}" for name, value in fields.items() if value)
    logger.warning("send_grant %s tool=%s session=%s%s", event, tool, _fingerprint(session_key), extras)


def issue(tool_name: str, args: Mapping) -> None:
    session_key, call_id = _identity()
    now = time.monotonic()
    tool, flat = normalise(tool_name, args)
    entry = _Entry(CallGrant(tool, flat), tool, flat, _signature(tool, flat), call_id, now + GRANT_TTL_SECONDS)
    with _lock:
        kept = [e for e in _entries.get(session_key, []) if e.expires + GRANT_TTL_SECONDS > now]
        _entries[session_key] = [*kept, entry][-MAX_GRANTS_PER_SESSION:]
    _log("issued", tool, session_key, call=call_id)


def _spend(candidates: list[_Entry], tool: str, flat: dict, signature: Optional[tuple]) -> Optional[_Entry]:
    exact = next((e for e in candidates if e.grant.spend(tool, flat)), None)
    if exact is not None:
        return exact
    return next((e for e in candidates if signature is not None and e.signature == signature
                 and e.grant.spend(e.tool, e.args)), None)


def _miss_reason(session_key: str, tool: str, flat: dict, now: float) -> str:
    same = lambda entries: any(e.tool == tool and e.args == flat for e in entries)
    mine = _entries.get(session_key, [])
    if same(e for e in mine if e.expires > now):
        return "digest_mismatch"
    if same(e for e in mine if e.expires <= now):
        return "expired"
    if any(same(entries) for key, entries in _entries.items() if key != session_key):
        return "other_session"
    return "digest_mismatch" if any(e.expires > now for e in mine) else "no_grant"


def redeem(tool_name: str, args: Mapping, *, gate: str = DRAFT_GATE) -> bool:
    session_key, _ = _identity()
    now = time.monotonic()
    tool, flat = normalise(tool_name, args)
    signature = _signature(tool, flat)
    with _lock:
        passes = [e for e in _gate_passes.get(session_key, []) if e.expires > now]
        used = _spend(passes, tool, flat, signature) if gate == MCP_GATE else None
        if used is not None:
            passes.remove(used)
        live = [e for e in _entries.get(session_key, []) if e.expires > now]
        if used is None:
            used = _spend(live, tool, flat, signature)
            if used is not None:
                if gate == DRAFT_GATE:
                    passes.append(_Entry(CallGrant(tool, used.args), used.tool, used.args, used.signature,
                                         used.call_id, now + GATE_PASS_TTL_SECONDS))
                _entries[session_key] = [e for e in _entries.get(session_key, []) if e is not used]
        reason = "" if used is not None else _miss_reason(session_key, tool, flat, now)
        _gate_passes[session_key] = passes
        if not passes:
            _gate_passes.pop(session_key, None)
        if not _entries.get(session_key):
            _entries.pop(session_key, None)
    if used is None:
        _log("miss", tool, session_key, gate=gate, reason=reason)
    else:
        _log("redeemed", tool, session_key, gate=gate, call=used.call_id)
    return used is not None


def clear_session(session_key: str) -> None:
    with _lock:
        _entries.pop(session_key, None)
        _gate_passes.pop(session_key, None)
