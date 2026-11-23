from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Callable, Literal, Optional

from agent.error_surface import PREVIEW_COPY_BY_CODE
from gateway.response_filters import is_intentional_silence_response, strip_trailing_silence_marker
from session_rules.turns import FAILED_TURN_DISPLAY_KIND
from tools.bot_dm_wire import BOT_REPLY_RULE
from tools.bot_mode_probe import NO_REPLY_MARKER

Role = Literal["user", "assistant"]

SYSTEM_NOTICE_PREFIX = "[System:"
MCP_RELOAD_NOTICE_PREFIX = "[IMPORTANT: MCP servers have been reloaded."

_DISCORD_TRIGGERING_NOTE_RE = re.compile(
    r"(^|\n)\[Triggering message id: `[^`\n]*` — use as `message_id` for reply/react/pin via the discord tools\.\]\n*"
)
_BOT_STAMP_NO_REPLY_RE = re.compile(
    r"^(Message from 🤖 .+? \(@[A-Za-z0-9_-]+(?:@[A-Za-z0-9_-]+)?\): )" + re.escape(NO_REPLY_MARKER) + " ")
_BOT_REPLY_RULE_SUFFIX = "\n\n" + BOT_REPLY_RULE


@dataclass(frozen=True, slots=True)
class MarkerRule:
    name: str
    role: Role
    project: Callable[[str], Optional[str]]


def _hide_when(matches: Callable[[str], bool]) -> Callable[[str], Optional[str]]:
    return lambda text: None if matches(text) else text


def _opens_with(prefix: str) -> Callable[[str], bool]:
    return lambda text: text.lstrip().startswith(prefix)


MARKER_RULES: tuple[MarkerRule, ...] = (
    MarkerRule("silence_reply", "assistant", _hide_when(is_intentional_silence_response)),
    MarkerRule("closing_silence_marker", "assistant", strip_trailing_silence_marker),
    MarkerRule("system_notice", "user", _hide_when(_opens_with(SYSTEM_NOTICE_PREFIX))),
    MarkerRule("mcp_reload_notice", "user", _hide_when(_opens_with(MCP_RELOAD_NOTICE_PREFIX))),
    MarkerRule("discord_triggering_note", "user", lambda text: _DISCORD_TRIGGERING_NOTE_RE.sub(r"\1", text)),
    MarkerRule("bot_dm_no_reply_lead", "user", lambda text: _BOT_STAMP_NO_REPLY_RE.sub(r"\1", text, count=1)),
    MarkerRule("bot_dm_reply_rule", "user", lambda text: text.removesuffix(_BOT_REPLY_RULE_SUFFIX)),
)


def display_text(role: Any, text: str) -> Optional[str]:
    for rule in MARKER_RULES:
        if rule.role == role and (text := rule.project(text)) is None:
            return None
    return text


_PERSON_DISPLAY_KINDS = frozenset({None, "steer"})
_MACHINE_TURN_PREFIXES = ("[IMPORTANT: Background process", "[ASYNC DELEGATION ")
PREVIEW_HIDDEN_SCAN = 64


def _surface_preview_copy(display_metadata: Any) -> Optional[str]:
    if isinstance(display_metadata, str):
        try:
            display_metadata = json.loads(display_metadata)
        except ValueError:
            return None
    surface = display_metadata.get("error_surface") if isinstance(display_metadata, dict) else None
    code = surface.get("code") if isinstance(surface, dict) else None
    return PREVIEW_COPY_BY_CODE.get(code) if isinstance(code, str) else None


def owner_display_text(role: Any, content: Any, display_kind: Any = None, display_metadata: Any = None) -> Optional[str]:
    """A stored row as an owner's transcript preview shows it, ``None`` when it shows nothing: a marker
    row, or an inbound user turn a person did not write: any machine ``display_kind``, or cron and
    background-result plumbing an older row carries untagged (the rule of Pal's ``InboundKind``). The
    row stays in history; this only decides what a preview reads."""
    text = content if isinstance(content, str) else ""
    if role == "user":
        from cron.constants import BOT_CHAT_TURN_PREFIX
        if display_kind not in _PERSON_DISPLAY_KINDS or text.strip().startswith(
                (BOT_CHAT_TURN_PREFIX, *_MACHINE_TURN_PREFIXES)):
            return None
    elif role != "assistant":
        return text
    elif display_kind == FAILED_TURN_DISPLAY_KIND and (copy := _surface_preview_copy(display_metadata)):
        return copy
    shown = display_text(role, text)
    return shown if shown and shown.strip() else None


def owner_visible_prompt(text: Any) -> str:
    """``text`` (a stored first-prompt preview) as an owner reads it, ``""`` when it is plumbing."""
    return owner_display_text("user", str(text or "")) or ""
