from __future__ import annotations

import copy
import logging
from pathlib import Path
from typing import Any

from hermes_cli.shared_catalog_config import edit_config_keys

logger = logging.getLogger(__name__)

_MAX_DEPTH = 4


def _swap(names: Any, renames: dict[str, str]) -> list[str] | None:
    if not isinstance(names, list) or not any(isinstance(n, str) and n.strip() in renames for n in names):
        return None
    swapped: list[str] = []
    for name in names:
        value = renames.get(name.strip(), name) if isinstance(name, str) else name
        if value not in swapped:
            swapped.append(value)
    return swapped


def _swap_binding(entry: Any, renames: dict[str, str]) -> Any:
    if not isinstance(entry, dict):
        return entry
    updated = copy.deepcopy(entry)
    skills = entry.get("skills")
    if isinstance(skills, list):
        updated["skills"] = _swap(skills, renames) or skills
    single = entry.get("skill")
    if isinstance(single, str) and single.strip() in renames:
        updated["skill"] = renames[single.strip()]
    return updated


def _collect_bindings(node: dict, path: tuple[str, ...], renames: dict[str, str], updates: dict[str, Any]) -> None:
    for key, value in node.items():
        if key == "channel_skill_bindings" and isinstance(value, list):
            swapped = [_swap_binding(entry, renames) for entry in value]
            if swapped != value:
                updates[".".join((*path, key))] = swapped
        elif isinstance(value, dict) and len(path) < _MAX_DEPTH:
            _collect_bindings(value, (*path, str(key)), renames, updates)


def config_reference_updates(config: dict, renames: dict[str, str]) -> dict[str, Any]:
    updates: dict[str, Any] = {}
    skills = config.get("skills")
    if isinstance(skills, dict) and (swapped := _swap(skills.get("auto_load"), renames)) is not None:
        updates["skills.auto_load"] = swapped
    for key, section in config.items():
        if key != "skills" and isinstance(section, dict):
            _collect_bindings(section, (str(key),), renames, updates)
    return updates


def _rewrite_cron_jobs(home: Path, renames: dict[str, str]) -> list[str]:
    from cron import jobs as cron_jobs

    changed: list[str] = []
    with cron_jobs.use_cron_store(home):
        for job in cron_jobs.list_jobs(include_disabled=True):
            swapped = _swap(list(job.get("skills") or []), renames)
            if swapped is None:
                continue
            try:
                cron_jobs.update_job(job["id"], {"skills": swapped})
            except ValueError as exc:
                logger.warning("Cannot repoint cron job %s at renamed skills: %s", job.get("id"), exc)
                continue
            changed.append(f"cron job {job.get('name') or job['id']}")
    return changed


def rewrite_references(home: Path, renames: dict[str, str]) -> list[str]:
    if not renames:
        return []
    updates = edit_config_keys(home / "config.yaml", lambda config: config_reference_updates(config, renames))
    return [*(f"config {key}" for key in sorted(updates)), *_rewrite_cron_jobs(home, renames)]
