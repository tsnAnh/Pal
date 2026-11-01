"""Which Bot Chat deliveries each session handed off, so an explicit Stop can reach the turns they started.

Process-local and bounded: a delivery is recorded when ``message_agent`` admitted it to the target
profile's authority. Stop takes (and forgets) every delivery its sessions originated.
"""
from __future__ import annotations

import threading
from collections import OrderedDict
from collections.abc import Iterable
from typing import Any

MAX_ORIGINS = 512
MAX_DELIVERIES_PER_ORIGIN = 64

_lock = threading.Lock()
_by_origin: OrderedDict[str, OrderedDict[str, dict[str, Any]]] = OrderedDict()


def record_handoff(origin_session_id: Any, *, delivery_id: Any, profile_home: Any, profile: Any = "") -> None:
    origin, delivery, home = (str(value or "").strip() for value in (origin_session_id, delivery_id, profile_home))
    if not (origin and delivery and home):
        return
    with _lock:
        deliveries = _by_origin.setdefault(origin, OrderedDict())
        _by_origin.move_to_end(origin)
        deliveries[delivery] = {"delivery_id": delivery, "profile_home": home, "profile": str(profile or "")}
        while len(deliveries) > MAX_DELIVERIES_PER_ORIGIN:
            deliveries.popitem(last=False)
        while len(_by_origin) > MAX_ORIGINS:
            _by_origin.popitem(last=False)


def take_handoffs(origin_session_ids: Iterable[Any]) -> list[dict[str, Any]]:
    taken: list[dict[str, Any]] = []
    with _lock:
        for origin in {str(value or "").strip() for value in origin_session_ids} - {""}:
            taken.extend((_by_origin.pop(origin, None) or {}).values())
    return taken
