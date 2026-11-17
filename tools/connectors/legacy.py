from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Literal, Optional
from urllib.parse import urlparse

from hermes_constants import get_hermes_home
from utils import read_json_or_empty

LegacySource = Literal["portal", "composio"]
_COMPOSIO_HOST = "composio.dev"


@dataclass(frozen=True)
class LegacyRecord:
    slug: str
    source: LegacySource
    last_seen: Optional[float]


def _portal_records(home: Path) -> Iterable[LegacyRecord]:
    for path in sorted((home / "cache" / "connectors").glob("*/*/*.json")):
        raw = read_json_or_empty(path)
        fetched_at = raw.get("fetched_at") if isinstance(raw, dict) else None
        yield LegacyRecord(path.stem, "portal", float(fetched_at) if isinstance(fetched_at, (int, float)) else None)


def _composio_records(servers: dict) -> Iterable[LegacyRecord]:
    for name, cfg in servers.items():
        host = (urlparse(str(cfg.get("url") or "")).hostname or "") if isinstance(cfg, dict) else ""
        if host == _COMPOSIO_HOST or host.endswith("." + _COMPOSIO_HOST):
            yield LegacyRecord(str(name), "composio", None)


def legacy_records(servers: dict, home: Optional[Path] = None) -> list[LegacyRecord]:
    home = home or get_hermes_home()
    latest: dict[str, LegacyRecord] = {}
    for record in [*_portal_records(home), *_composio_records(servers)]:
        held = latest.get(record.slug)
        if held is None or (record.last_seen or 0) > (held.last_seen or 0):
            latest[record.slug] = record
    return list(latest.values())
