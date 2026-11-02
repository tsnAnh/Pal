from __future__ import annotations

import json
import os
import shutil
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from hermes_cli.config_backend import config_exists
from hermes_cli.shared_catalog_tree import copy_tree, tree_snapshot
from hermes_constants import get_default_hermes_root, get_shared_root

BACKUP_PREFIX = "migration-backup-"
MANIFEST_NAME = "manifest.json"
STATUS_PREPARED = "prepared"
STATUS_COMMITTED = "committed"
STATUS_DONE = "done"
STATUS_ROLLING_BACK = "rolling-back"
STATUS_ROLLED_BACK = "rolled-back"
STATUS_SUPERSEDED = "superseded"
MIGRATED_CONFIG_KEYS = (("skills", "disabled"), ("skills", "enabled"), ("mcp_servers",))


@dataclass(frozen=True)
class BotSource:
    name: str
    home: Path
    skills_dir: Path
    config: dict


def plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    return value


def read_config(path: Path) -> dict:
    from hermes_cli.config import read_user_config_raw

    return plain(read_user_config_raw(path))


def discover_homes() -> list[tuple[str, Path]]:
    from hermes_cli.profiles import _iter_named_profile_dirs

    return [("default", get_default_hermes_root()), *((p.name, p) for p in _iter_named_profile_dirs())]


def discover_sources() -> list[BotSource]:
    return [BotSource(name, home, home / "skills", read_config(home / "config.yaml")) for name, home in discover_homes()]


def utc_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def atomic_json(path: Path, data: dict) -> None:
    from utils import atomic_json_write

    atomic_json_write(path, data, indent=2)


def backups() -> list[Path]:
    shared = get_shared_root()
    if not shared.is_dir():
        return []
    return sorted(p for p in shared.glob(f"{BACKUP_PREFIX}*") if (p / MANIFEST_NAME).is_file())


def read_manifest(backup: Path) -> dict:
    return json.loads((backup / MANIFEST_NAME).read_text(encoding="utf-8-sig"))


def write_status(backup: Path, manifest: dict, status: str, **extra: Any) -> None:
    manifest.update(status=status, **extra)
    atomic_json(backup / MANIFEST_NAME, manifest)


def newest_backup(statuses: tuple[str, ...]) -> tuple[Path, dict] | None:
    for backup in reversed(backups()):
        manifest = read_manifest(backup)
        if manifest.get("status") in statuses:
            return backup, manifest
    return None


def create_backup(sources: list[BotSource]) -> tuple[Path, dict]:
    shared = get_shared_root()
    shared.mkdir(parents=True, exist_ok=True)
    for stale in shared.glob(f".{BACKUP_PREFIX}*.tmp"):
        shutil.rmtree(stale, ignore_errors=True)
    stamp = utc_stamp()
    final = shared / f"{BACKUP_PREFIX}{stamp}"
    counter = 2
    while final.exists():
        final = shared / f"{BACKUP_PREFIX}{stamp}-{counter}"
        counter += 1
    staging = shared / f".{final.name}.tmp"
    staging.mkdir()
    bots = []
    for source in sources:
        dest = staging / source.name
        dest.mkdir()
        config_path = source.home / "config.yaml"
        had_skills = source.skills_dir.is_dir()
        had_config = config_exists(config_path)
        if had_skills:
            copy_tree(source.skills_dir, dest / "skills")
        if had_config:
            shutil.copy2(config_path, dest / "config.yaml")  # config-reader: ok — byte-exact backup, gated by require_file_tooling
        bots.append({"name": source.name, "home": str(source.home), "had_skills": had_skills,
                     "had_config": had_config})
    manifest = {"version": 2, "status": STATUS_PREPARED, "created": stamp, "bots": bots,
                "catalog_skills": [], "catalog_digests": {}, "catalog_origins": [], "catalog_mcp": [],
                "catalog_files": [], "catalog_carried": {}, "plan": {}, "renames": [], "leftovers": {},
                "skipped_homes": [], "failed_bots": {}}
    atomic_json(staging / MANIFEST_NAME, manifest)
    os.replace(staging, final)
    return final, manifest


def sources_from_backup(backup: Path, manifest: dict) -> list[BotSource]:
    return [
        BotSource(b["name"], Path(b["home"]), backup / b["name"] / "skills", read_config(backup / b["name"] / "config.yaml"))
        for b in manifest["bots"]
    ]


def migrated_config_view(config: dict) -> dict:
    view: dict[str, Any] = {}
    for path in MIGRATED_CONFIG_KEYS:
        node: Any = config
        for part in path:
            node = node.get(part) if isinstance(node, dict) else None
        if node is not None:
            view[".".join(path)] = node
    return view


def drift_since_backup(backup: Path, manifest: dict) -> list[str]:
    homes = dict(discover_homes())
    recorded = {b["name"]: b for b in manifest["bots"]}
    problems = [f"profile {name} was added" for name in sorted(set(homes) - set(recorded))]
    problems += [f"profile {name} was removed" for name in sorted(set(recorded) - set(homes))]
    for name in sorted(set(recorded) & set(homes)):
        live, saved = tree_snapshot(homes[name] / "skills"), tree_snapshot(backup / name / "skills")
        changed = sorted(k for k in set(live) | set(saved) if live.get(k) != saved.get(k))
        if changed:
            problems.append(f"{name}: {len(changed)} skill path(s) changed, e.g. {', '.join(changed[:3])}")
        if migrated_config_view(read_config(homes[name] / "config.yaml")) != migrated_config_view(
                read_config(backup / name / "config.yaml")):
            problems.append(f"{name}: skills or MCP settings in config.yaml changed")
    return problems
