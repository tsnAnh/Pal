from __future__ import annotations

import copy
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Iterable

from hermes_cli.shared_catalog import catalog_active, catalog_lock, catalog_skills_dir
from hermes_cli.shared_catalog_scan import Found, discover_skills, skill_name

logger = logging.getLogger(__name__)

ORIGINS_FILE = ".origins.json"
ORIGIN_BUNDLED = "bundled"
ORIGIN_MIGRATED = "migrated"
ORIGIN_BOT = "bot"
ORIGIN_HUB = "hub"
_NAMES_TTL_SECONDS = 2.0

_cache_lock = threading.Lock()
_origins_cache: dict[str, tuple[tuple[int, int], dict[str, dict]]] = {}
_names_cache: dict[str, tuple[Any, float, frozenset[str]]] = {}
_manifest_cache: dict[str, tuple[tuple[int, int], frozenset[str]]] = {}


def origins_path() -> Path:
    return catalog_skills_dir() / ORIGINS_FILE


def _file_signature(path: Path) -> tuple[int, int] | None:
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    return stat.st_mtime_ns, stat.st_size


def _load_origins(path: Path) -> dict[str, dict]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        logger.warning("Cannot read %s (%s); treating every catalog skill as unowned", path, exc)
        return {}
    if not isinstance(raw, dict):
        return {}
    return {str(name): dict(entry) for name, entry in raw.items() if isinstance(entry, dict)}


def read_origins() -> dict[str, dict]:
    path = origins_path()
    signature = _file_signature(path)
    if signature is None:
        return {}
    key = str(path)
    with _cache_lock:
        cached = _origins_cache.get(key)
    if cached is not None and cached[0] == signature:
        return copy.deepcopy(cached[1])
    origins = _load_origins(path)
    with _cache_lock:
        _origins_cache[key] = (signature, origins)
    return copy.deepcopy(origins)


def _invalidate() -> None:
    with _cache_lock:
        _origins_cache.clear()
        _names_cache.clear()
        _manifest_cache.clear()


def write_origins_locked(origins: dict[str, dict]) -> None:
    from utils import atomic_json_write

    path = origins_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_json_write(path, origins, indent=2, sort_keys=True)
    _invalidate()


def origin_record(origin: str, owners: Iterable[str]) -> dict:
    ordered = sorted(set(owners))
    record: dict[str, Any] = {"origin": origin, "owner": ordered[0] if len(ordered) == 1 else None}
    if len(ordered) > 1:
        record["owners"] = ordered
    return record


def record_origins(updates: dict[str, dict]) -> None:
    if not updates:
        return
    with catalog_lock():
        origins = _load_origins(origins_path())
        merged = {**origins, **updates}
        if merged != origins:
            write_origins_locked(merged)


def forget_origins(names: Iterable[str]) -> None:
    drop = set(names)
    with catalog_lock():
        origins = _load_origins(origins_path())
        kept = {n: e for n, e in origins.items() if n not in drop}
        if kept == origins:
            return
        if kept:
            write_origins_locked(kept)
        else:
            origins_path().unlink(missing_ok=True)
            _invalidate()


def owners_of(record: dict | None) -> set[str]:
    if not record:
        return set()
    owners = {str(o) for o in record.get("owners") or []}
    if record.get("owner"):
        owners.add(str(record["owner"]))
    return owners


def current_owner() -> str:
    from hermes_cli.profiles import current_profile_name

    return current_profile_name(default="default") or "default"


def _manifest_names(path: Path) -> frozenset[str]:
    signature = _file_signature(path)
    if signature is None:
        return frozenset()
    key = str(path)
    with _cache_lock:
        cached = _manifest_cache.get(key)
    if cached is not None and cached[0] == signature:
        return cached[1]
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return frozenset()
    names = frozenset(n for n in (line.split(":", 1)[0].strip() for line in lines) if n and not n.startswith("#"))
    with _cache_lock:
        _manifest_cache[key] = (signature, names)
    return names


def bundled_names() -> set[str]:
    root = catalog_skills_dir()
    names = _manifest_names(root / ".bundled_manifest") | _manifest_names(root / ".curator_suppressed")
    return set(names) | {n for n, rec in read_origins().items() if rec.get("origin") == ORIGIN_BUNDLED}


def _scan_names(root: Path) -> frozenset[str]:
    return frozenset(skill_name(item) for item in discover_skills(root))


def _dir_signature(root: Path) -> tuple[int, ...]:
    stamps = []
    try:
        stamps.append(root.stat().st_mtime_ns)
        with os.scandir(root) as entries:
            stamps.extend(e.stat().st_mtime_ns for e in entries if e.is_dir(follow_symlinks=True))
    except FileNotFoundError:
        return ()
    return tuple(stamps)


def catalog_skill_names() -> frozenset[str]:
    root = catalog_skills_dir()
    key = str(root)
    signature = (_dir_signature(root), _file_signature(origins_path()))
    now = time.monotonic()
    with _cache_lock:
        cached = _names_cache.get(key)
    if cached is not None and cached[0] == signature and now - cached[1] < _NAMES_TTL_SECONDS:
        return cached[2]
    names = _scan_names(root) if root.is_dir() else frozenset()
    with _cache_lock:
        _names_cache[key] = (signature, now, names)
    return names


def default_off_names() -> set[str]:
    return set(catalog_skill_names()) - bundled_names()


def default_off_among(names: Iterable[str]) -> list[str]:
    if not catalog_active():
        return []
    wanted = set(names)
    off = default_off_names()
    return sorted({name for item, name in iter_catalog_skills()
                   if name in off and (name in wanted or item.path.name in wanted)})


def catalog_disabled_names(skills_cfg: Any) -> set[str]:
    if not catalog_active():
        return set()
    from hermes_cli.shared_catalog_config import name_list

    enabled = set(name_list(skills_cfg.get("enabled"))) if isinstance(skills_cfg, dict) else set()
    return default_off_names() - enabled


def grant_new_skill(name: str, origin: str) -> None:
    from hermes_cli.shared_catalog_config import update_skill_lists
    from hermes_constants import get_config_path

    owner = current_owner()
    record_origins({name: origin_record(origin, [owner])})
    update_skill_lists(get_config_path(), enable=[name])


def curator_scope_allows(name: str) -> bool:
    if not catalog_active():
        return True
    if name in bundled_names():
        from agent.skill_utils import get_disabled_skill_names

        return name not in get_disabled_skill_names()
    return current_owner() in owners_of(read_origins().get(name))


def _inside_catalog(skill_dir: Path) -> bool:
    root = catalog_skills_dir()
    return any(candidate.is_relative_to(base)
               for candidate in (skill_dir.absolute(), skill_dir.resolve())
               for base in (root.absolute(), root.resolve()))


def bot_may_write_skill(skill_dir: Path) -> bool:
    if not catalog_active() or not _inside_catalog(skill_dir):
        return True
    from tools.skill_usage import read_skill_name

    name = read_skill_name(skill_dir / "SKILL.md", skill_dir.name)
    record = read_origins().get(name) or {}
    if name in bundled_names() or record.get("origin") in (ORIGIN_BUNDLED, ORIGIN_HUB):
        return False
    return bool(record.get("owner")) and record["owner"] == current_owner()


def reassign_owner(old: str, new: str | None) -> list[str]:
    if not catalog_active() or not any(old in owners_of(r) for r in read_origins().values()):
        return []
    try:
        with catalog_lock():
            origins = _load_origins(origins_path())
            moved = sorted(name for name, record in origins.items() if old in owners_of(record))
            if not moved:
                return []
            updated = dict(origins)
            for name in moved:
                owners = (owners_of(origins[name]) - {old}) | ({new} if new else set())
                updated[name] = origin_record(origins[name].get("origin", ORIGIN_BOT), owners)
            write_origins_locked(updated)
            return moved
    except OSError as exc:
        logger.warning("Could not move catalog skill ownership from %s to %s: %s", old, new or "nobody", exc)
        return []


def iter_catalog_skills() -> list[tuple[Found, str]]:
    return [(item, skill_name(item)) for item in discover_skills(catalog_skills_dir())]
