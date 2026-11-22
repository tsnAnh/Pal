from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from gateway.desk.model import DeskItem
from gateway.desk.store import DB_NAME, DeskStore
from utils.files import mtime_is_racy

Signature = tuple[tuple[int, int] | None, ...]


@dataclass(frozen=True)
class _Seen:
    signature: Signature | None
    revisions: dict[str, int]


def _signature(home: Path) -> Signature | None:
    stats = []
    for name in (DB_NAME, f"{DB_NAME}-wal"):
        try:
            stat = (home / name).stat()
        except OSError:
            stats.append(None)
            continue
        if mtime_is_racy(stat.st_mtime_ns):
            return None
        stats.append((stat.st_mtime_ns, stat.st_size))
    return None if stats[0] is None else tuple(stats)


class DeskFeed:
    def __init__(self) -> None:
        self._seen: dict[Path, _Seen] = {}
        self._primed = False

    def changes(self, homes: Iterable[Path]) -> list[tuple[Path, DeskItem]]:
        moved: list[tuple[Path, DeskItem]] = []
        for home in homes:
            if not (home / DB_NAME).exists():
                self._seen.pop(home, None)
                continue
            before = self._seen.get(home)
            signature = _signature(home)
            if signature is not None and before is not None and before.signature == signature:
                continue
            items = DeskStore(home).listing()
            if self._primed:
                known = before.revisions if before is not None else {}
                moved += [(home, item) for item in items if known.get(item.id) != item.revision]
            self._seen[home] = _Seen(signature, {item.id: item.revision for item in items})
        self._primed = True
        return moved
