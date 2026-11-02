from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Iterator

from hermes_cli.config_backend import require_file_tooling
from hermes_cli.shared_catalog import (
    catalog_active, catalog_dir, catalog_lock, catalog_skills_dir, has_transport, mcp_definitions_path, merge_server,
    read_mcp_definitions, update_mcp_definitions,
)
from hermes_cli.shared_catalog_backup import (
    STATUS_COMMITTED, STATUS_DONE, STATUS_PREPARED, STATUS_ROLLED_BACK, STATUS_ROLLING_BACK, discover_homes,
    newest_backup, read_config, write_status,
)
from hermes_cli.shared_catalog_config import dotted_key, edit_config_keys, name_list, skill_list_updates
from hermes_cli.shared_catalog_origins import bundled_names, forget_origins, iter_catalog_skills, owners_of, read_origins
from hermes_cli.shared_catalog_refs import rewrite_references
from hermes_cli.shared_catalog_tree import (
    copy_entry, copy_tree, entry_digest, prune_empty_parents, remove_volatile,
)
from hermes_constants import CATALOG_MIGRATED_MARKER

logger = logging.getLogger(__name__)

ROLLBACK_STATUSES = (STATUS_PREPARED, STATUS_COMMITTED, STATUS_DONE, STATUS_ROLLING_BACK)
EDITS_DIR = "post-migration-edits"

Say = Callable[[str], None]


def _digest(path: Path) -> str:
    from tools.skills_sync import dir_hash

    return entry_digest(path) if path.is_symlink() or path.is_file() else dir_hash(path)


def remove_catalog_content(manifest: dict) -> None:
    root = catalog_skills_dir()
    for key in manifest["catalog_skills"]:
        target = root / key
        remove_volatile(target)
        prune_empty_parents(target, root)
    for rel in manifest["catalog_files"]:
        (root / rel).unlink(missing_ok=True)
        prune_empty_parents(root / rel, root)
    for rel, digest in manifest.get("catalog_carried", {}).items():
        target = root / rel
        if (target.exists() or target.is_symlink()) and entry_digest(target) == digest:
            target.unlink()
            prune_empty_parents(target, root)
    forget_origins(manifest.get("catalog_origins", []))
    names = set(manifest["catalog_mcp"])
    if names:
        update_mcp_definitions(lambda definitions: [definitions.pop(n, None) for n in names])
        if not update_mcp_definitions(lambda definitions: bool(definitions)):
            mcp_definitions_path().unlink(missing_ok=True)


def _post_migration_skills(manifest: dict) -> list[tuple[str, Path, str]]:
    known, bundled = set(manifest["catalog_skills"]), bundled_names()
    return [(item.key, item.path, name) for item, name in iter_catalog_skills()
            if item.key not in known and name not in bundled]


def _preserve_edited(backup: Path, manifest: dict, say: Say) -> None:
    root = catalog_skills_dir()
    for key, digest in manifest["catalog_digests"].items():
        path = root / key
        if (path.exists() or path.is_symlink()) and _digest(path) != digest:
            copy_entry(path, backup / EDITS_DIR / key)
            say(f"  {key} changed after migration; its latest copy is kept in {backup / EDITS_DIR / key}")


def _copy_back_skills(
    home: Path, config: dict, name: str, post: list[tuple[str, Path, str]], origins: dict[str, dict],
) -> list[str]:
    skills_cfg = config.get("skills") if isinstance(config.get("skills"), dict) else {}
    enabled, disabled = set(name_list(skills_cfg.get("enabled"))), set(name_list(skills_cfg.get("disabled")))
    restored = []
    for key, path, skill_name in post:
        wanted = (skill_name in enabled and skill_name not in disabled) or name in owners_of(origins.get(skill_name))
        target = home / "skills" / key
        if wanted and not (target.exists() or target.is_symlink()):
            copy_entry(path, target)
            restored.append(skill_name)
    return restored


def _restored_entry(shared: dict, entry: Any, original: Any) -> dict:
    full = merge_server(shared, entry if isinstance(entry, dict) else {})
    if isinstance(original, dict) and "enabled" not in original and full.get("enabled") is True:
        full.pop("enabled")
    return full


def _mcp_restore_updates(
    config: dict, definitions: dict[str, dict], back: dict[str, str], dangling: list[str], saved: dict,
) -> dict[str, Any]:
    servers = config.get("mcp_servers")
    if not isinstance(servers, dict):
        return {}
    updates: dict[str, Any] = {}
    for name, entry in servers.items():
        target = back[name] if name in back and back[name] not in servers else name
        if has_transport(entry):
            if target != name:
                updates[dotted_key("mcp_servers", name)] = None
                updates[dotted_key("mcp_servers", target)] = entry
            continue
        shared = definitions.get(name)
        if shared is None:
            dangling.append(name)
            continue
        if target != name:
            updates[dotted_key("mcp_servers", name)] = None
        updates[dotted_key("mcp_servers", target)] = _restored_entry(shared, entry, saved.get(target))
    return updates


def _restore_bot(
    name: str, home: Path, backup: Path, manifest: dict, post: list[tuple[str, Path, str]],
    definitions: dict[str, dict], origins: dict[str, dict], say: Say,
) -> None:
    record = next((b for b in manifest["bots"] if b["name"] == name), None)
    plan = manifest["plan"].get(name) or {"disabled_add": [], "renames": {}, "mcp": {}}
    if record is not None and record["had_skills"]:
        copy_tree(backup / name / "skills", home / "skills", overwrite=False)
    restored = _copy_back_skills(home, read_config(home / "config.yaml"), name, post, origins)
    if restored:
        say(f"  {name}: copied back {len(restored)} skill(s) added after migration ({', '.join(sorted(restored)[:5])})")
    back = {m["final"]: orig for orig, m in plan["mcp"].items() if m["final"] != orig}
    saved = read_config(backup / name / "config.yaml").get("mcp_servers")
    saved = saved if isinstance(saved, dict) else {}
    dangling: list[str] = []

    def edit(config: dict) -> dict[str, Any]:
        return {
            **skill_list_updates(config, disable_remove=plan["disabled_add"], drop_enabled_key=True, prune_empty=True),
            **_mcp_restore_updates(config, definitions, back, dangling, saved),
        }

    edit_config_keys(home / "config.yaml", edit)
    for server in dangling:
        say(f"  {name}: MCP server {server} has no shared definition anymore; left as is")
    for line in rewrite_references(home, {new: old for old, new in plan["renames"].items()}):
        say(f"  {name}: restored {line}")


def _homes_to_restore(manifest: dict, say: Say) -> Iterator[tuple[str, Path]]:
    live = dict(discover_homes())
    for bot in manifest["bots"]:
        if bot["name"] not in live and not Path(bot["home"]).is_dir():
            say(f"  {bot['name']}: profile folder no longer exists; skipped")
    yield from live.items()


def _seed_unrecorded_bots(homes: list[tuple[str, Path]], say: Say) -> None:
    from hermes_cli.profiles import seed_profile_skills

    for name, home in homes:
        if seed_profile_skills(home, quiet=True) is None:
            say(f"  {name}: created after the migration and could not be given the bundled skills; run `hermes -p {name} update` to seed them")
        else:
            say(f"  {name}: created after the migration; seeded the bundled skills")


def rollback(*, say: Say = print) -> int:
    require_file_tooling("Shared catalog rollback")
    with catalog_lock():
        found = newest_backup(ROLLBACK_STATUSES)
        if found is None:
            say("No migration backup found; nothing to roll back.")
            return 1
        backup, manifest = found
        marker = catalog_dir() / CATALOG_MIGRATED_MARKER
        if not catalog_active():
            remove_catalog_content(manifest)
            write_status(backup, manifest, STATUS_ROLLED_BACK)
            say("The shared catalog was never switched on; removed what the interrupted migration had published.")
            return 0
        write_status(backup, manifest, STATUS_ROLLING_BACK)
        post, definitions, origins = _post_migration_skills(manifest), read_mcp_definitions(), read_origins()
        skipped = [b["name"] for b in manifest["bots"] if not Path(b["home"]).is_dir()]
        recorded = {b["name"] for b in manifest["bots"]}
        unrecorded: list[tuple[str, Path]] = []
        for name, home in _homes_to_restore(manifest, say):
            _restore_bot(name, home, backup, manifest, post, definitions, origins, say)
            if name not in recorded:
                unrecorded.append((name, home))
        _preserve_edited(backup, manifest, say)
        remove_catalog_content(manifest)
        marker.unlink(missing_ok=True)
        _seed_unrecorded_bots(unrecorded, say)
        write_status(backup, manifest, STATUS_ROLLED_BACK, rollback_skipped=skipped)
        say(f"Rolled back to {backup}")
        return 0
