from __future__ import annotations

import time
from dataclasses import dataclass, replace
from enum import IntEnum, StrEnum

ENGAGED_WINDOW_SECONDS = 300.0
SILENT_TRANSPORT_SECONDS = 45.0


class ClientKind(StrEnum):
    DESKTOP = "desktop"
    IOS = "ios"
    TUI = "tui"
    CLI = "cli"
    WEB = "web"


class AttentionState(StrEnum):
    FOREGROUND = "foreground"
    BACKGROUND = "background"
    IDLE = "idle"


class Attention(IntEnum):
    PARKED = 0
    REACHABLE = 1
    ATTACHED = 2
    ENGAGED = 3


@dataclass(frozen=True, slots=True)
class Device:
    kind: ClientKind
    device_id: str
    label: str
    app_version: str


@dataclass(frozen=True, slots=True)
class ReachSlot:
    device: Device
    accepts_offers: bool
    same_host: bool
    attention: AttentionState
    attention_at: float
    last_input_at: float | None


_SLOT_ATTR = "reach_slot"
_LAST_FRAME_ATTR = "last_frame_at"


def slot_of(transport) -> ReachSlot | None:
    slot = getattr(transport, _SLOT_ATTR, None)
    return slot if isinstance(slot, ReachSlot) else None


def declare(transport, device: Device, *, accepts_offers: bool, same_host: bool,
            attention: AttentionState, now: float | None = None) -> ReachSlot:
    previous = slot_of(transport)
    stamp = time.time() if now is None else now
    slot = ReachSlot(device=device, accepts_offers=accepts_offers, same_host=same_host,
                     attention=attention, attention_at=stamp,
                     last_input_at=previous.last_input_at if previous else None)
    setattr(transport, _SLOT_ATTR, slot)
    return slot


def report_attention(transport, state: AttentionState, now: float | None = None) -> ReachSlot | None:
    slot = slot_of(transport)
    if slot is None:
        return None
    updated = replace(slot, attention=state, attention_at=time.time() if now is None else now)
    setattr(transport, _SLOT_ATTR, updated)
    return updated


def record_input(transport, now: float | None = None) -> ReachSlot | None:
    slot = slot_of(transport)
    if slot is None:
        return None
    updated = replace(slot, last_input_at=time.time() if now is None else now)
    setattr(transport, _SLOT_ATTR, updated)
    return updated


def last_frame_at(transport) -> float | None:
    value = getattr(transport, _LAST_FRAME_ATTR, None)
    return value if isinstance(value, (int, float)) else None


def attention_of(slot: ReachSlot, *, last_frame: float | None, now: float) -> Attention:
    if last_frame is not None and now - last_frame > SILENT_TRANSPORT_SECONDS:
        return Attention.PARKED
    recent_input = slot.last_input_at is not None and now - slot.last_input_at <= ENGAGED_WINDOW_SECONDS
    if slot.attention is AttentionState.FOREGROUND or recent_input:
        return Attention.ENGAGED
    return Attention.ATTACHED


def origin_of(transport) -> dict | None:
    slot = slot_of(transport)
    if slot is None:
        return None
    return {"kind": slot.device.kind.value, "label": slot.device.label, "same_host": slot.same_host}
