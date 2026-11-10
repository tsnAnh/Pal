from __future__ import annotations

from gateway.reach_presence import PUSH_CLIENT_KINDS, Attention, AttentionState, attention_of, last_frame_at, slot_of
from gateway.session_authorities import all_authorities


def served_authorities(authority) -> list:
    authorities = [item for item in all_authorities(getattr(authority, "runner", None)) if item is not None]
    return authorities if any(item is authority for item in authorities) else [*authorities, authority]


def transports_of(authorities, device_id: str) -> list:
    found = []
    for authority in authorities:
        for transport in list(authority.events.values()):
            slot = slot_of(transport)
            if slot is not None and slot.device.device_id == device_id and not any(t is transport for t in found):
                found.append(transport)
    return found


def live_attention(authorities, now: float) -> dict[str, Attention]:
    levels: dict[str, Attention] = {}
    for authority in authorities:
        for transport in list(authority.events.values()):
            slot = slot_of(transport)
            if slot is None:
                continue
            level = attention_of(slot, last_frame=last_frame_at(transport), now=now)
            device_id = slot.device.device_id
            levels[device_id] = max(level, levels.get(device_id, Attention.PARKED))
    return levels


def anyone_attentive(authorities, now: float) -> bool:
    for authority in authorities:
        for transport in list(authority.events.values()):
            slot = slot_of(transport)
            if slot is None or attention_of(slot, last_frame=last_frame_at(transport), now=now) is not Attention.ENGAGED:
                continue
            if slot.device.kind in PUSH_CLIENT_KINDS and slot.attention is not AttentionState.FOREGROUND:
                continue
            return True
    return False
