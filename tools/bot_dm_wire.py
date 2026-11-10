from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Literal, Optional

_DELIVERY_ID = r"[0-9a-f]{32,64}"
_HANDLE = r"[A-Za-z0-9_-]{1,64}"
_STAMP_RE = re.compile(rf"^Message from 🤖 (?P<name>.+?) \(@(?P<handle>{_HANDLE})(?:@(?P<conn>{_HANDLE}))?\): (?P<body>.*)$",
                       re.DOTALL)
_STAMP_HANDLE_RE = re.compile(r"^(Message from 🤖 .+? \(@)([A-Za-z0-9_-]+)(\): )", re.DOTALL)
_LEGACY_RE = re.compile(r"^\[Message from agent '(?P<name>[^']{1,64})'\]\s*(?P<body>.*)$", re.DOTALL)
_DELIVERY_KEY_RE = re.compile(rf"^(?:bot:)?(?P<id>{_DELIVERY_ID})(?P<retry>:retry)?$")
_DELIVERY_REQUEST_ID_RE = re.compile(rf"^bot:(?P<id>{_DELIVERY_ID})(?::retry)?$")
_RELAY_REPLY_RE = re.compile(r"^Reply from (?P<label>.+?):\n(?P<reply>.*?)\n?$", re.DOTALL)
_RELAY_FAILURE_RE = re.compile(r"^Delivery to (?P<label>.+?) failed(?: \[reason: (?P<reason>[a-z_]+)\])?: ", re.DOTALL)
_TARGET_LABEL_RE = re.compile(rf"^@(?P<handle>{_HANDLE})(?: on peer '(?P<peer>[a-z0-9][a-z0-9_-]{{0,63}})'| on (?P<conn>.+))?$",
                              re.DOTALL)
EMPTY_RELAY_REPLY = "(empty reply)"


@dataclass(frozen=True, slots=True)
class SenderStamp:
    display_name: str
    handle: str
    connection: Optional[str]
    body: str
    form: Literal["stamp", "legacy"]


@dataclass(frozen=True, slots=True)
class DeliveryKey:

    delivery_id: str

    @classmethod
    def parse(cls, raw: object) -> Optional[DeliveryKey]:
        match = _DELIVERY_KEY_RE.match(str(raw or "").strip())
        return cls(match["id"]) if match else None

    @classmethod
    def from_request_id(cls, raw: object) -> Optional[DeliveryKey]:
        match = _DELIVERY_REQUEST_ID_RE.match(str(raw or "").strip())
        return cls(match["id"]) if match else None

    @property
    def request_id(self) -> str:
        return f"bot:{self.delivery_id}"

    @property
    def retry_request_id(self) -> str:
        return f"bot:{self.delivery_id}:retry"


@dataclass(frozen=True, slots=True)
class TargetLabel:
    kind: Literal["local", "peer", "relay"]
    handle: str
    peer: Optional[str] = None
    connection: Optional[str] = None


@dataclass(frozen=True, slots=True)
class RelayOutcome:
    replied: bool
    reply: str
    reason: str


def format_sender_stamp(display_name: str, handle: str, body: str) -> str:
    return f"Message from 🤖 {display_name} (@{handle}): " + body


def restamp_sender(message: str, handle_form: str) -> Optional[str]:
    match = _STAMP_HANDLE_RE.match(message)
    if match is None:
        return None
    return f"{match.group(1)}{handle_form}{match.group(3)}{message[match.end():]}"


def split_sender_stamp(text: object) -> Optional[SenderStamp]:
    raw = str(text or "")
    if (match := _STAMP_RE.match(raw)) is not None:
        return SenderStamp(match["name"], match["handle"], match["conn"], match["body"], "stamp")
    if (match := _LEGACY_RE.match(raw)) is not None:
        return SenderStamp(match["name"], match["name"], None, match["body"], "legacy")
    return None


def format_peer_label(handle: str, peer_name: str) -> str:
    return f"@{handle} on peer '{peer_name}'"


def format_relay_label(handle: str, connection: str) -> str:
    return f"@{handle} on {connection}"


def parse_target_label(label: object) -> Optional[TargetLabel]:
    match = _TARGET_LABEL_RE.match(str(label or ""))
    if match is None:
        return None
    if match["peer"]:
        return TargetLabel("peer", match["handle"], peer=match["peer"])
    if match["conn"]:
        return TargetLabel("relay", match["handle"], connection=match["conn"])
    return TargetLabel("local", match["handle"])


def format_relay_reply(label: str, reply: Optional[str]) -> str:
    return f"Reply from {label}:\n{reply or EMPTY_RELAY_REPLY}"


def format_relay_failure(label: str, reason: Optional[str], error: str) -> str:
    code = str(reason or "").strip()
    tag = f" [reason: {code}]" if code else ""
    return f"Delivery to {label} failed{tag}: {error}"


def parse_relay_output(output: str) -> Optional[RelayOutcome]:
    if (match := _RELAY_REPLY_RE.match(output)) is not None:
        reply = match["reply"]
        return RelayOutcome(True, "" if reply == EMPTY_RELAY_REPLY else reply, "")
    if (match := _RELAY_FAILURE_RE.match(output)) is not None:
        return RelayOutcome(False, "", match["reason"] or "")
    return None


def parse_live_output(output: str) -> Optional[dict]:
    try:
        payload = json.loads(output.strip())
    except ValueError:
        return None
    if not isinstance(payload, dict) or DeliveryKey.parse(payload.get("delivery_id")) is None:
        return None
    return payload if isinstance(payload.get("status"), str) else None
