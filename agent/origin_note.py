from __future__ import annotations

import logging
import re
from typing import Any, NamedTuple, Optional

from agent.message_content import flatten_message_text
from agent.surface_switch import identity_line_value

logger = logging.getLogger("run_agent")

_NOTE_PREFIX = "[System: The user is now writing from "
_SAME_HOST = "It is the machine your tools run on."
_OTHER_HOST = "It is not the machine your tools run on: files you create are not on that device."
_NOTE_SCAN_TAIL = 200
_LABEL_NOISE = re.compile(r"[\[\]]")

_APP_NAMES = {
    "desktop": "Hermes desktop app",
    "ios": "Hermes iOS app",
    "tui": "Hermes terminal UI",
    "cli": "Hermes command line",
    "web": "Hermes web dashboard",
}
_BASELINE_PLATFORMS = {"desktop": "desktop", "ios": "ios", "tui": "tui", "cli": "cli"}
_CAVEATS = {
    "desktop": "Markdown renders in full on this device and files can be delivered as MEDIA: cards.",
    "ios": "This is a phone: only inline Markdown renders, so keep replies compact, skip tables, "
           "headings and code fences, and give file paths as plain text.",
    "tui": "This is a terminal: Markdown does not render and files are given as plain paths.",
    "cli": "This is a terminal: Markdown does not render and files are given as plain paths.",
    "web": "Assume plain Markdown; no desktop-app-only widgets or panes.",
}
_NOTE_RE = re.compile(
    re.escape(_NOTE_PREFIX) + r"(?P<label>[^\[\]]*?) \((?P<app>" + "|".join(map(re.escape, _APP_NAMES.values())) + r")\)\. "
    r"(?P<host>" + re.escape(_SAME_HOST) + "|" + re.escape(_OTHER_HOST) + ")")


class OriginSignature(NamedTuple):
    kind: str
    label: str
    same_host: bool


def _clean_label(label: str) -> str:
    return " ".join(_LABEL_NOISE.sub("", label).split())


def _signature(origin: Any) -> Optional[OriginSignature]:
    if not isinstance(origin, dict) or origin.get("kind") not in _APP_NAMES:
        return None
    label = _clean_label(str(origin.get("label") or ""))
    if not label:
        return None
    return OriginSignature(origin["kind"], label, origin.get("same_host") is True)


def render_note(signature: OriginSignature) -> str:
    host = _SAME_HOST if signature.same_host else _OTHER_HOST
    return (f"{_NOTE_PREFIX}{signature.label} ({_APP_NAMES[signature.kind]}). {host}] "
            f"{_CAVEATS[signature.kind]}")


def _parse(text: str) -> Optional[OriginSignature]:
    matches = list(_NOTE_RE.finditer(text))
    if not matches:
        return None
    last = matches[-1]
    kind = next((kind for kind, app in _APP_NAMES.items() if app == last["app"]), None)
    if kind is None:
        return None
    return OriginSignature(kind, last["label"], last["host"] == _SAME_HOST)


def _last_announced(conversation_history: Any) -> Optional[OriginSignature]:
    for msg in reversed((conversation_history or [])[-_NOTE_SCAN_TAIL:]):
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        sidecar = msg.get("api_content")
        text = (sidecar if isinstance(sidecar, str) else "") + "\n" + flatten_message_text(msg.get("content"))
        if _NOTE_PREFIX in text and (found := _parse(text)) is not None:
            return found
    return None


def _baseline(prompt: Any, signature: OriginSignature) -> bool:
    described = identity_line_value(prompt, "Platform") if isinstance(prompt, str) else ""
    return signature.same_host and _BASELINE_PLATFORMS.get(signature.kind) == described


def stage_origin_note(agent: Any, active_system_prompt: Any, messages: Any) -> bool:
    origin = getattr(agent, "_client_origin", None)
    if origin is not None:
        agent._client_origin = None
    if getattr(agent, "provider", None) == "moa" or getattr(agent, "api_mode", None) == "codex_app_server":
        return False
    signature = _signature(origin)
    if signature is None:
        return False
    told = _last_announced(messages)
    if told == signature or (told is None and _baseline(active_system_prompt, signature)):
        return False
    agent._origin_note = render_note(signature)
    logger.info("Session %s: turn written from %s (%s); delivering the origin as a turn note.",
                getattr(agent, "session_id", None), signature.label, signature.kind)
    return True
