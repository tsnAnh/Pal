from __future__ import annotations

import json
import re
from collections import Counter
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from gateway.audience.model import Audience
from gateway.audience.posture import audience_of_key
from gateway.display_markers import owner_display_text
from gateway.message_timestamps import strip_leading_message_timestamps
from gateway.proactive_scorecard.mining import DEFAULT_EXCLUDED_SOURCES, _calls, _text_of
from hermes_state_session_search import is_compression_edge
from persistence.authority.vocabulary import LEGACY_LOCAL_SOURCES, NOT_CLIENT_LABELS
from persistence.conversation.messages import TranscriptRead, TranscriptRow, TranscriptView
from persistence.conversation.sessions import SessionLineageKind, SessionRecord, SessionWindow
from persistence_assembly import open_persistence_reader
from session_rules.turns import (
    TYPED_ASK, extract_user_instruction_from_skill_message, strip_steer_markers, user_originated_turn_view,
)
from tools.bot_dm_wire import parse_relay_output, split_sender_stamp
from tools.tool_search import TOOL_CALL_NAME, normalize_tool_call_entries

MACHINE_SOURCES = (NOT_CLIENT_LABELS - {"local", "unknown", "recovered"}) | frozenset(DEFAULT_EXCLUDED_SOURCES) | {
    "msgraph_webhook", "wecom_callback", "ntfy", "oneshot"}
LOCAL_SOURCES = (LEGACY_LOCAL_SOURCES - MACHINE_SOURCES) | {"local"}
OWNER_CHAT_TYPES = frozenset({"dm", "direct", "private"})
_SOURCE_LABEL = re.compile(r"[a-z0-9_-]{1,24}")
_INJECTED_PROMPT_PREFIXES = (
    "[Continuing toward your standing goal", "[Heartbeat \u2014 ", "[/loop wakeup #", "[IMPORTANT: ", "[ASYNC DELEGATION ",
)
_BACKFILL_MARKER = "\n\n[New message]\n"
_AUDIO_PATH_NOTE = re.compile(r"\n?\[User sent audio: [^\n]*\]")
_CONTEXT_SWITCH_KINDS = frozenset({"model_switch", "personality_switch"})


class Author(Enum):
    OWNER = "owner"
    MACHINE = "machine"
    BOT = "bot"


@dataclass(frozen=True, slots=True)
class Call:
    call_id: str
    name: str
    arguments: dict


@dataclass(frozen=True, slots=True)
class Step:
    text: str
    calls: tuple[Call, ...]


@dataclass(slots=True)
class Turn:
    author: Author
    text: str
    at: float
    steps: list[Step] = field(default_factory=list)
    results: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class Transcripts:
    conversations: tuple[tuple[Turn, ...], ...]
    counted: Mapping[str, int]
    skipped: Mapping[str, Mapping[str, int]]


def _surface(record: SessionRecord) -> str:
    return (record.created_source or record.source) if record.source == "local" else record.source


def _label(source: str) -> str:
    return source if _SOURCE_LABEL.fullmatch(source) else "other"


def _chat_type(record: SessionRecord) -> str:
    parts = str(record.session_key or "").split(":")
    keyed = parts[3] if len(parts) >= 5 and parts[0] == "agent" else ""
    return str(record.chat_type or keyed).strip().lower()


def _skip_reason(record: SessionRecord) -> str | None:
    surface = _surface(record)
    if {record.source, surface} & MACHINE_SOURCES or record.lineage_kind is SessionLineageKind.DELEGATE:
        return "machine_source"
    if record.session_key and audience_of_key(record.session_key) is Audience.MEMBER:
        return "not_owner_chat"
    chat_type = _chat_type(record)
    if chat_type in OWNER_CHAT_TYPES or (not chat_type and {record.source, surface} & LOCAL_SOURCES):
        return None
    return "not_owner_chat"


def _conversation_root(record: SessionRecord, records: Mapping[str, SessionRecord]) -> str:
    seen = {record.session_id}
    while (parent := records.get(record.parent_session_id or "")) and parent.session_id not in seen:
        if not is_compression_edge({"started_at": record.started_at},
                                   {"end_reason": parent.end_reason, "ended_at": parent.ended_at}):
            break
        seen.add(parent.session_id)
        record = parent
    return record.session_id


def _typed_words(content: str) -> str:
    text = content.rpartition(_BACKFILL_MARKER)[2]
    while True:
        before = text
        text = strip_leading_message_timestamps(text.lstrip())[0]
        if text.startswith("[Replying to"):
            text = text.rpartition('"]\n\n')[2] if '"]\n\n' in text else ""
        elif text.startswith("[The user sent"):
            text = text.rpartition("]\n\n")[2] if "]\n\n" in text else ""
        if text == before:
            return _AUDIO_PATH_NOTE.sub("", text)


def _opening(row: TranscriptRow) -> Turn | None:
    if row.display_kind in _CONTEXT_SWITCH_KINDS:
        return None
    view = user_originated_turn_view(row.as_wire_row())
    if view is None:
        wake = row.display_kind or _text_of(row.content).startswith(_INJECTED_PROMPT_PREFIXES)
        return Turn(Author.MACHINE, "", row.timestamp) if wake and not row.compressed_summary else None
    asked = (row.display_metadata or {}).get(TYPED_ASK)
    stored = asked if isinstance(asked, str) else _text_of(view.get("content"))
    shown = owner_display_text("user", stored, row.display_kind, row.display_metadata)
    if shown is None and stored.strip():
        return Turn(Author.MACHINE, "", row.timestamp)
    typed = _typed_words(strip_steer_markers(shown or ""))
    text = extract_user_instruction_from_skill_message(typed) or ""
    if split_sender_stamp(text):
        return Turn(Author.BOT, "", row.timestamp)
    if parse_relay_output(text) or text.startswith(_INJECTED_PROMPT_PREFIXES):
        return Turn(Author.MACHINE, "", row.timestamp)
    return Turn(Author.OWNER, text, row.timestamp)


def _calls_of(row: TranscriptRow) -> Iterator[Call]:
    for raw in row.tool_calls if isinstance(row.tool_calls, (list, tuple)) else ():
        if not isinstance(raw, Mapping) or not isinstance(raw.get("function") or {}, Mapping):
            continue
        call_id = str(raw.get("id") or raw.get("call_id") or "")
        for name, arguments in _calls([raw]):
            if name != TOOL_CALL_NAME:
                yield Call(call_id, name, arguments)
                continue
            for entry in normalize_tool_call_entries(arguments)[0]:
                yield Call(call_id, entry["name"], entry["arguments"])


def _turns(rows: list[TranscriptRow]) -> tuple[Turn, ...]:
    turns: list[Turn] = []
    for row in rows:
        if row.role == "user":
            if opened := _opening(row):
                turns.append(opened)
        elif not turns:
            continue
        elif row.role == "assistant" and not (row.display_kind or row.compressed_summary):
            shown = owner_display_text("assistant", _text_of(row.content)) or ""
            turns[-1].steps.append(Step(shown, tuple(_calls_of(row))))
        elif row.role == "tool" and row.tool_call_id:
            turns[-1].results[row.tool_call_id] = _text_of(row.content)
    return tuple(turns)


def _identities(row: TranscriptRow) -> tuple[object, ...]:
    copied = (row.role, row.timestamp, json.dumps([row.content, row.tool_calls], default=str))
    return (copied, row.message_uid) if row.message_uid else (copied,)


def read_transcripts(home: Path, since: float) -> Transcripts:
    skipped: dict[str, Counter] = {}
    counted: Counter = Counter()
    with open_persistence_reader(home) as store:
        entries = store.sessions.search_sessions(window=SessionWindow(limit=None))
        records = {entry.session.session_id: entry.session for entry in entries}
        segments: dict[str, list[SessionRecord]] = {}
        for entry in entries:
            if entry.last_active is not None and entry.last_active < since:
                continue
            if reason := _skip_reason(entry.session):
                skipped.setdefault(reason, Counter())[_label(entry.session.source)] += 1
                continue
            segments.setdefault(_conversation_root(entry.session, records), []).append(entry.session)
        seen: set[object] = set()
        conversations = []
        for root in sorted(segments, key=lambda session_id: (records[session_id].started_at, session_id)):
            rows = []
            for record in sorted(segments[root], key=lambda item: (item.started_at, item.session_id)):
                for row in store.messages.read_transcript(record.session_id,
                                                          TranscriptRead(view=TranscriptView.DISPLAY)):
                    identities = _identities(row)
                    if row.timestamp >= since and not seen.intersection(identities):
                        rows.append(row)
                    seen.update(identities)
            if turns := _turns(rows):
                conversations.append(turns)
                counted[_label(records[root].source)] += 1
    return Transcripts(tuple(conversations), dict(sorted(counted.items())),
                       {reason: dict(sorted(by_source.items())) for reason, by_source in sorted(skipped.items())})
