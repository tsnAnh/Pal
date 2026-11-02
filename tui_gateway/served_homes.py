"""Profile homes the canonical multiplexed gateway serves, for the change watcher.

The watcher thread runs outside any turn and cannot ask the runner, so the runner's one
served-profile seam (``_note_served_profiles`` / ``_unserve_profile``) publishes here and the
watcher reads a snapshot. Legacy per-RPC profile hosting keeps its own set in ``server.py``.
"""

from __future__ import annotations

import threading
from collections.abc import Mapping
from pathlib import Path

_lock = threading.Lock()
_homes: dict[str, Path] = {}


def replace(homes: Mapping[str, Path]) -> None:
    global _homes
    with _lock:
        _homes = {str(name): Path(home) for name, home in homes.items()}


def forget(name: str) -> None:
    global _homes
    with _lock:
        _homes = {n: h for n, h in _homes.items() if n != name}


def snapshot() -> tuple[Path, ...]:
    return tuple(_homes.values())
