from __future__ import annotations

import threading
import time
from collections import deque

WINDOW_SECONDS = 60.0
PER_BOT = 5
PER_DEVICE = 10

_lock = threading.Lock()
_hits: dict[tuple[str, str], deque[float]] = {}


def claim(bot: str, device_id: str, *, now: float | None = None) -> float | None:
    stamp = time.monotonic() if now is None else now
    with _lock:
        buckets = {("bot", f"{bot}\0{device_id}"): PER_BOT, ("device", device_id): PER_DEVICE}
        waits = []
        for key, limit in buckets.items():
            hits = _hits.setdefault(key, deque())
            while hits and stamp - hits[0] >= WINDOW_SECONDS:
                hits.popleft()
            if len(hits) >= limit:
                waits.append(WINDOW_SECONDS - (stamp - hits[0]))
        if waits:
            return max(waits)
        for key in buckets:
            _hits[key].append(stamp)
        return None


def reset() -> None:
    with _lock:
        _hits.clear()
