from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Optional


class ItemKind(str, Enum):
    ASK = "ask"
    HANDOFF = "handoff"
    SEND = "send"


class ItemState(str, Enum):
    POSTING = "posting"
    OPEN = "open"
    APPROVED = "approved"
    EXECUTING = "executing"
    DONE = "done"
    DECLINED = "declined"
    EXPIRED = "expired"
    UNKNOWN = "unknown"
    CANCELLED = "cancelled"
    FAILED = "failed"


TERMINAL_STATES = frozenset({ItemState.DONE, ItemState.DECLINED, ItemState.EXPIRED, ItemState.UNKNOWN,
                             ItemState.CANCELLED, ItemState.FAILED})


@dataclass(frozen=True)
class Origin:
    session_key: str
    profile: str


@dataclass(frozen=True)
class Recipient:
    platform: str
    scope_id: str
    user_id: Optional[str]
    conversation_id: Optional[str]
    thread_ts: Optional[str]
    direct: bool


@dataclass(frozen=True)
class AskPayload:
    question: str
    target: Recipient
    anchor_ts: Optional[str]


@dataclass(frozen=True)
class HandoffPayload:
    request: str
    why: str
    requester_id: str
    requester_name: str
    conversation_id: str
    thread_ts: Optional[str]
    where: str = ""


@dataclass(frozen=True)
class SendPayload:
    to: Recipient
    text: str
    digest: str
    wait_for_reply: bool
    wait_minutes: Optional[int]
    label: str


Payload = AskPayload | HandoffPayload | SendPayload


@dataclass(frozen=True)
class DeskItem:
    id: str
    kind: ItemKind
    state: ItemState
    revision: int
    origin: Origin
    owner_id: str
    platform: str
    scope_id: str
    payload: Payload
    outcome: Optional[dict[str, Any]]
    created_at: float
    expires_at: float
    settled_at: Optional[float]
    delivered_at: Optional[float]


@dataclass(frozen=True)
class OwnerCard:
    item_id: str
    title: str
    lines: tuple[str, ...]
    choices: tuple[str, ...]
    expires_at: float


def item_id_for_call(session_id: str, turn_id: str, tool_call_id: str) -> str:
    digest = hashlib.sha256("\x1f".join((session_id, turn_id, tool_call_id)).encode()).hexdigest()
    return "dk_" + digest[:16]


def send_digest(to: Recipient, text: str) -> str:
    raw = "\x1f".join((to.platform, to.scope_id, to.user_id or "", to.conversation_id or "", to.thread_ts or "", text))
    return hashlib.sha256(raw.encode()).hexdigest()


def payload_to_json(payload: Payload) -> dict[str, Any]:
    return asdict(payload)


def payload_from_json(kind: ItemKind, raw: dict[str, Any]) -> Payload:
    if kind is ItemKind.ASK:
        return AskPayload(raw["question"], Recipient(**raw["target"]), raw.get("anchor_ts"))
    if kind is ItemKind.HANDOFF:
        return HandoffPayload(**raw)
    return SendPayload(Recipient(**raw["to"]), raw["text"], raw["digest"], raw["wait_for_reply"],
                       raw.get("wait_minutes"), raw["label"])
