from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from hermes_cli.config_backend import Changes, FileBackend
from hermes_cli.shared_catalog import (
    catalog_active, catalog_lock, catalog_skills_dir, effective_mcp_servers, has_transport,
)
from hermes_cli.shared_catalog_backup import read_config
from hermes_cli.shared_catalog_config import dotted_key, name_list, update_skill_lists
from hermes_cli.shared_catalog_origins import (
    ORIGIN_BOT, bundled_names, catalog_disabled_names, iter_catalog_skills, origin_record, read_origins,
    write_origins_locked,
)
from hermes_cli.shared_catalog_refs import rewrite_references
from hermes_cli.shared_catalog_scan import discover_skills, rewrite_skill_name, skill_name
from hermes_cli.shared_catalog_tree import copy_entry, file_digest, prune_empty_parents, remove_volatile


def enabled_catalog_skills(profile_dir: Path, *, include_bundled: bool = True) -> list[tuple[str, Path, str]]:
    skills_cfg = read_config(profile_dir / "config.yaml").get("skills")
    disabled = set(name_list(skills_cfg.get("disabled") if isinstance(skills_cfg, dict) else None))
    disabled |= catalog_disabled_names(skills_cfg)
    bundled = bundled_names()
    return [(item.key, item.path, name) for item, name in iter_catalog_skills()
            if name not in disabled and (include_bundled or name not in bundled)]


def _export_ignore(directory: str, contents: list) -> set:
    from hermes_cli.profiles import _export_credential_entries, _non_exportable_entries

    return _non_exportable_entries(directory, contents) | _export_credential_entries(directory, contents)


def _expanded_server_updates(profile_servers: Any) -> dict[str, Any]:
    if not isinstance(profile_servers, dict):
        return {}
    effective = effective_mcp_servers(profile_servers)
    return {dotted_key("mcp_servers", name): effective[name] for name, entry in profile_servers.items()
            if name in effective and not has_transport(entry) and has_transport(effective[name])}


def materialize_catalog(profile_dir: Path, staged: Path) -> None:
    if not catalog_active():
        return
    for key, path, _ in enabled_catalog_skills(profile_dir):
        dest = staged / "skills" / key
        if not (dest.exists() or dest.is_symlink()):
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(path, dest, symlinks=True, ignore=_export_ignore)
    staged_config = staged / "config.yaml"
    try:
        staged_doc = FileBackend.read_path(staged_config) or {}
    except FileNotFoundError:
        return
    if updates := _expanded_server_updates(staged_doc.get("mcp_servers")):
        FileBackend.write_path(staged_config, Changes(set=updates))


def _unique(base: str, taken: set[str], owner: str, leaf_suffix: str = "") -> str:
    parent, _, leaf = base.rpartition("/")
    stem = leaf[: len(leaf) - len(leaf_suffix)] if leaf_suffix else leaf
    candidate, counter = f"{owner}-{stem}{leaf_suffix}", 2
    while (f"{parent}/{candidate}" if parent else candidate) in taken:
        candidate = f"{owner}-{stem}-{counter}{leaf_suffix}"
        counter += 1
    return f"{parent}/{candidate}" if parent else candidate


def _same_content(imported: Path, existing: Path) -> bool:
    from tools.skills_sync import dir_hash

    if imported.is_dir() and existing.is_dir():
        return dir_hash(imported) == dir_hash(existing)
    if imported.is_file() and existing.is_file():
        return file_digest(imported) == file_digest(existing)
    return False


def adopt_profile_skills(profile_dir: Path, owner: str) -> list[str]:
    local = profile_dir / "skills"
    if not catalog_active() or not local.is_dir():
        return []
    root = catalog_skills_dir()
    wanted: list[str] = []
    renames: dict[str, str] = {}
    created: dict[str, dict] = {}
    adopted = discover_skills(local)
    with catalog_lock():
        present = {name: item.path for item, name in iter_catalog_skills()}
        keys = {item.key for item, _ in iter_catalog_skills()}
        bundled = bundled_names()
        for item in adopted:
            name = skill_name(item)
            if name in present and _same_content(item.path, present[name]):
                final_name = name
            else:
                clash = name in present or item.key in keys
                final_key = _unique(item.key, keys, owner, ".md" if item.flat else "") if clash else item.key
                final_name = f"{owner}-{name}" if clash else name
                dest = root / final_key
                remove_volatile(dest)
                copy_entry(item.path, dest)
                if clash:
                    rewrite_skill_name(dest if item.flat else dest / "SKILL.md", final_name)
                    renames[name] = final_name
                keys.add(final_key)
                present[final_name] = dest
                created[final_name] = origin_record(ORIGIN_BOT, [owner])
            if final_name not in bundled:
                wanted.append(final_name)
        if created:
            write_origins_locked({**read_origins(), **created})
    for item in adopted:
        remove_volatile(item.path)
        prune_empty_parents(item.path, local)
    if wanted:
        update_skill_lists(profile_dir / "config.yaml", enable=wanted)
    rewrite_references(profile_dir, renames)
    return wanted
