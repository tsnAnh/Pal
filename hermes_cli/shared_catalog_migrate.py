from __future__ import annotations

import json
import logging
import os
import shutil
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

from hermes_cli.config_backend import require_file_tooling
from hermes_cli.shared_catalog import (
    catalog_active, catalog_dir, catalog_lock, catalog_skills_dir, has_transport, split_bot_secrets,
    update_mcp_definitions,
)
from hermes_cli.shared_catalog_backup import (
    STATUS_COMMITTED, STATUS_DONE, STATUS_PREPARED, STATUS_SUPERSEDED, BotSource, atomic_json, create_backup,
    discover_sources, drift_since_backup, newest_backup, sources_from_backup, utc_stamp, write_status,
)
from hermes_cli.shared_catalog_config import dotted_key, edit_config_keys, name_list, skill_list_updates
from hermes_cli.shared_catalog_origins import (
    ORIGIN_BUNDLED, ORIGIN_HUB, ORIGIN_MIGRATED, origin_record, read_origins, write_origins_locked,
)
from hermes_cli.shared_catalog_refs import rewrite_references
from hermes_cli.shared_catalog_scan import discover_skills, rewrite_skill_name, skill_name
from hermes_cli.shared_catalog_tree import (
    carry_tree, copy_entry, copy_tree, entry_digest, file_digest, is_volatile, prune_empty_parents, remove_matching,
    remove_volatile,
)
from hermes_constants import CATALOG_MIGRATED_MARKER

logger = logging.getLogger(__name__)

SKILL_META_FILES = (".bundled_manifest", ".usage.json", ".hub/lock.json")
CARRIED_TREES = (".archive", ".curator_backups", ".hub/quarantine", ".restore-backups")
REGENERABLE = (".locks", ".hub/index-cache")
_MAX_LISTED = 5

Say = Callable[[str], None]


class MigrationDrift(RuntimeError):
    pass


@dataclass
class SkillEntry:
    key: str
    final_key: str
    name: str
    final_name: str
    digest: str
    source: Path
    flat: bool = False
    link: bool = False
    origin: str = ORIGIN_MIGRATED
    owners: dict[str, str] = field(default_factory=dict)
    rels: dict[str, str] = field(default_factory=dict)


@dataclass
class McpEntry:
    name: str
    final_name: str
    payload: dict
    owners: dict[str, str] = field(default_factory=dict)


@dataclass
class BotPlan:
    disabled_add: list[str] = field(default_factory=list)
    enabled_add: list[str] = field(default_factory=list)
    renames: dict[str, str] = field(default_factory=dict)
    mcp: dict[str, dict] = field(default_factory=dict)
    consumed: list[str] = field(default_factory=list)


@dataclass
class Plan:
    skills: list[SkillEntry] = field(default_factory=list)
    mcp: list[McpEntry] = field(default_factory=list)
    bots: dict[str, BotPlan] = field(default_factory=dict)


def _disabled_names(config: dict) -> list[str]:
    skills_cfg = config.get("skills")
    return name_list(skills_cfg.get("disabled")) if isinstance(skills_cfg, dict) else []


def _suffix(key: str) -> str:
    return ".md" if key.endswith(".md") else ""


def _unique_key(key: str, bot: str, taken: set[str]) -> str:
    parent, _, leaf = key.rpartition("/")
    ext = _suffix(leaf)
    stem = leaf[: len(leaf) - len(ext)] if ext else leaf
    candidate = f"{bot}-{stem}{ext}"
    counter = 2
    while (f"{parent}/{candidate}" if parent else candidate) in taken:
        candidate = f"{bot}-{stem}-{counter}{ext}"
        counter += 1
    return f"{parent}/{candidate}" if parent else candidate


def _unique_name(name: str, bot: str, taken: set[str]) -> str:
    candidate = f"{bot}-{name}"
    counter = 2
    while candidate in taken:
        candidate = f"{bot}-{name}-{counter}"
        counter += 1
    return candidate


def _manifest_names(path: Path) -> set[str]:
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return set()
    return {n for n in (line.split(":", 1)[0].strip() for line in lines) if n}


def _hub_names(path: Path) -> set[str]:
    try:
        installed = json.loads(path.read_text(encoding="utf-8-sig")).get("installed")
    except (OSError, ValueError, AttributeError):
        return set()
    return {str(k) for k in installed} if isinstance(installed, dict) else set()


def _plan_skills(sources: list[BotSource]) -> list[SkillEntry]:
    from tools.skills_sync import dir_hash

    bundled: set[str] = set().union(*(_manifest_names(s.skills_dir / ".bundled_manifest") for s in sources))
    hub: set[str] = set().union(*(_hub_names(s.skills_dir / ".hub" / "lock.json") for s in sources))
    by_key: dict[str, list[SkillEntry]] = {}
    by_name: dict[tuple[str, str], SkillEntry] = {}
    taken_keys: set[str] = set()
    taken_names: set[str] = set()
    ordered: list[SkillEntry] = []
    for source in sources:
        for item in discover_skills(source.skills_dir):
            digest = file_digest(item.path) if item.flat else dir_hash(item.path)
            name = skill_name(item)
            rel = item.path.relative_to(source.skills_dir).as_posix()
            match = next((e for e in by_key.get(item.key, []) if e.digest == digest), None) or by_name.get((name, digest))
            if match is not None:
                match.owners[source.name] = name
                match.rels[source.name] = rel
                continue
            final_key = item.key if item.key not in taken_keys else _unique_key(item.key, source.name, taken_keys)
            renamed = final_key != item.key or name in taken_names
            final_name = _unique_name(name, source.name, taken_names) if renamed else name
            origin = ORIGIN_MIGRATED
            if not renamed and name in bundled:
                origin = ORIGIN_BUNDLED
            elif not renamed and name in hub:
                origin = ORIGIN_HUB
            entry = SkillEntry(item.key, final_key, name, final_name, digest, item.path, item.flat, item.link, origin,
                               {source.name: name}, {source.name: rel})
            by_key.setdefault(item.key, []).append(entry)
            by_name[(name, digest)] = entry
            taken_keys.add(final_key)
            taken_names.add(final_name)
            ordered.append(entry)
    return ordered


def _server_enabled(entry: dict) -> bool:
    from hermes_cli.tools_config import _parse_enabled_flag
    from tools.mcp_tool_common import mcp_server_enabled

    return mcp_server_enabled(entry) and not _parse_enabled_flag(entry.get("disabled", False), default=False)


def _plan_mcp(sources: list[BotSource]) -> tuple[list[McpEntry], dict[str, dict]]:
    variants: dict[str, list[McpEntry]] = {}
    taken: set[str] = set()
    ordered: list[McpEntry] = []
    per_bot: dict[str, dict] = {}
    for source in sources:
        servers = source.config.get("mcp_servers")
        if not isinstance(servers, dict):
            continue
        mapping: dict[str, dict] = {}
        for name, entry in servers.items():
            if not has_transport(entry):
                continue
            payload, _ = split_bot_secrets(entry)
            match = next((e for e in variants.get(name, []) if e.payload == payload), None)
            if match is None:
                final = name if name not in taken else _unique_name(name, source.name, taken)
                match = McpEntry(name, final, payload)
                variants.setdefault(name, []).append(match)
                taken.add(final)
                ordered.append(match)
            match.owners[source.name] = name
            mapping[name] = {"final": match.final_name, "payload": payload}
        if mapping:
            per_bot[source.name] = mapping
    return ordered, per_bot


def _plan_bot(source: BotSource, entries: list[SkillEntry]) -> BotPlan:
    from agent.skill_utils import ESSENTIAL_SKILLS

    lowered = {n.lower() for n in _disabled_names(source.config)}
    plan = BotPlan()
    for entry in entries:
        owned = entry.owners.get(source.name)
        if entry.origin == ORIGIN_BUNDLED:
            if owned is None and entry.final_name not in ESSENTIAL_SKILLS:
                plan.disabled_add.append(entry.final_name)
        elif owned is not None and owned.lower() not in lowered:
            plan.enabled_add.append(entry.final_name)
        if owned is not None and owned != entry.final_name:
            plan.renames[owned] = entry.final_name
        if source.name in entry.rels:
            plan.consumed.append(entry.rels[source.name])
    plan.disabled_add = sorted(plan.disabled_add)
    plan.enabled_add = sorted(plan.enabled_add)
    return plan


def plan_migration(sources: list[BotSource]) -> Plan:
    skills = _plan_skills(sources)
    mcp, mcp_by_bot = _plan_mcp(sources)
    plan = Plan(skills=skills, mcp=mcp)
    for source in sources:
        plan.bots[source.name] = _plan_bot(source, skills)
        plan.bots[source.name].mcp = mcp_by_bot.get(source.name, {})
    return plan


def _publish_dir(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    staging = dest.parent / f".{dest.name}.migrating"
    shutil.rmtree(staging, ignore_errors=True)
    copy_tree(src, staging)
    remove_volatile(dest)
    os.replace(staging, dest)


def _published_digest(dest: Path, entry: SkillEntry) -> str:
    from tools.skills_sync import dir_hash

    return entry_digest(dest) if dest.is_symlink() or entry.flat else dir_hash(dest)


def _publish_skills(plan: Plan) -> dict[str, str]:
    root = catalog_skills_dir()
    digests: dict[str, str] = {}
    for entry in plan.skills:
        dest = root / entry.final_key
        renamed = entry.final_name != entry.name
        if entry.flat:
            remove_volatile(dest)
            copy_entry(entry.source, dest)
            if renamed:
                rewrite_skill_name(dest, entry.final_name)
        elif entry.link and not renamed:
            remove_volatile(dest)
            copy_entry(entry.source, dest)
        else:
            _publish_dir(entry.source, dest)
            if renamed:
                rewrite_skill_name(dest / "SKILL.md", entry.final_name)
        digests[entry.final_key] = _published_digest(dest, entry)
    return digests


def _publish_origins(plan: Plan) -> list[str]:
    records = {e.final_name: origin_record(e.origin, e.owners) for e in plan.skills}
    origins = read_origins()
    merged = {**origins, **records}
    if merged != origins:
        write_origins_locked(merged)
    return sorted(records)


def _merge_manifest_lines(paths: list[Path]) -> str:
    merged: dict[str, str] = {}
    for path in paths:
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            name, _, digest = line.strip().partition(":")
            if name:
                merged.setdefault(name.strip(), digest.strip())
    return "".join(f"{name}:{digest}\n" for name, digest in sorted(merged.items()))


def _merge_json_maps(paths: list[Path], key: str | None) -> dict:
    merged: dict[str, Any] = {}
    top: dict[str, Any] = {}
    for path in paths:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        for k, v in data.items():
            top.setdefault(k, v)
        mapping = data.get(key) if key else data
        if isinstance(mapping, dict):
            for k, v in mapping.items():
                merged.setdefault(k, v)
    if key is None:
        return merged
    return {**top, key: merged}


def _union_json(left: Any, right: Any) -> Any:
    if isinstance(left, dict) and isinstance(right, dict):
        return {**{k: _union_json(left[k], right[k]) if k in right else left[k] for k in left},
                **{k: v for k, v in right.items() if k not in left}}
    if isinstance(left, list) and isinstance(right, list):
        return [*left, *(item for item in right if item not in left)]
    return left


def _write_text(path: Path, text: str) -> None:
    from utils import atomic_write_text

    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(path, text)


def _publish_skill_meta(sources: list[BotSource], plan: Plan) -> list[str]:
    root = catalog_skills_dir()
    written: list[str] = []
    for rel in SKILL_META_FILES:
        paths = [root / rel, *(s.skills_dir / rel for s in sources)]
        if not any(p.is_file() for p in paths):
            continue
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if rel == ".bundled_manifest":
            _write_text(dest, _merge_manifest_lines(paths))
        elif rel == ".usage.json":
            atomic_json(dest, _merge_json_maps(paths, None))
        else:
            lock = _merge_json_maps(paths, "installed")
            keep = {k: v for k, v in lock["installed"].items() if (root / str(v.get("install_path", ""))).exists()}
            atomic_json(dest, {**lock, "installed": keep})
        written.append(rel)
        for source in sources:
            if (source.skills_dir / rel).is_file():
                plan.bots[source.name].consumed.append(rel)
    for source in sources:
        if not source.skills_dir.is_dir():
            continue
        for desc in sorted(source.skills_dir.rglob("DESCRIPTION.md")):
            rel = desc.relative_to(source.skills_dir)
            if any(p.startswith(".") for p in rel.parts):
                continue
            target = root / rel
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(desc, target)
            if file_digest(target) == file_digest(desc):
                plan.bots[source.name].consumed.append(rel.as_posix())
    return written


def _concat_text(paths: list[Path]) -> str:
    return "".join(p.read_text(encoding="utf-8-sig") for p in paths)


def _union_lines(paths: list[Path]) -> str:
    names = sorted({line.strip() for p in paths for line in p.read_text(encoding="utf-8-sig").splitlines() if line.strip()})
    return "\n".join(names) + "\n"


def _union_taps(paths: list[Path]) -> str:
    merged: Any = None
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            logger.warning("Skipping unreadable %s", path)
            continue
        merged = data if merged is None else _union_json(merged, data)
    return json.dumps({} if merged is None else merged, indent=2) + "\n"


def _newest_text(paths: list[Path]) -> str:
    return max(paths, key=lambda p: p.stat().st_mtime).read_text(encoding="utf-8-sig")


_TEXT_MERGERS: dict[str, Callable[[list[Path]], str]] = {
    ".hub/audit.log": _concat_text,
    ".curator_ledger.jsonl": _concat_text,
    ".curator_suppressed": _union_lines,
    ".hub/taps.json": _union_taps,
    ".curator_state": _newest_text,
}


def _carry_text_files(sources: list[BotSource], plan: Plan, published: dict[str, str]) -> None:
    root = catalog_skills_dir()
    for rel, merge in _TEXT_MERGERS.items():
        parts = [(s, s.skills_dir / rel) for s in sources if (s.skills_dir / rel).is_file()]
        if not parts:
            continue
        _write_text(root / rel, merge([path for _, path in parts]))
        published[rel] = file_digest(root / rel)
        for source, _ in parts:
            plan.bots[source.name].consumed.append(rel)


def _carry_state(sources: list[BotSource], plan: Plan) -> dict[str, str]:
    root = catalog_skills_dir()
    published: dict[str, str] = {}
    for rel in CARRIED_TREES:
        taken: dict[str, str] = {}
        for source in sources:
            src = source.skills_dir / rel
            if not src.is_dir():
                continue
            files = carry_tree(src, root / rel, taken, source.name)
            published.update({f"{rel}/{k}": v for k, v in files.items()})
            plan.bots[source.name].consumed.append(rel)
    _carry_text_files(sources, plan, published)
    for source in sources:
        plan.bots[source.name].consumed.extend(
            rel for rel in REGENERABLE if (source.skills_dir / rel).exists() or (source.skills_dir / rel).is_symlink())
    return published


def _publish_mcp(plan: Plan) -> list[str]:
    payloads = {e.final_name: e.payload for e in plan.mcp}
    if payloads:
        update_mcp_definitions(lambda definitions: definitions.update(payloads))
    return sorted(payloads)


def _mcp_updates(config: dict, mapping: dict[str, dict]) -> dict[str, Any]:
    servers = config.get("mcp_servers")
    if not isinstance(servers, dict) or not mapping:
        return {}
    updates: dict[str, Any] = {}
    for name, entry in servers.items():
        planned = mapping.get(name)
        if planned is None or not has_transport(entry) or split_bot_secrets(entry)[0] != planned["payload"]:
            continue
        _, bot_only = split_bot_secrets(entry)
        if planned["final"] != name:
            updates[dotted_key("mcp_servers", name)] = None
        updates[dotted_key("mcp_servers", planned["final"])] = {"enabled": _server_enabled(entry), **bot_only}
    return updates


def _enable_bot_skills(home: Path, names: list[str]) -> None:
    edit_config_keys(home / "config.yaml", lambda config: skill_list_updates(config, enable=names))


def _enable_skills_before_marker(backup: Path, manifest: dict) -> None:
    from hermes_cli.config_backend import ConfigBackendUnavailable

    written: list[str] = list(manifest.get("enabled_written") or [])
    for bot in manifest["bots"]:
        plan = manifest["plan"].get(bot["name"])
        if plan is None or bot["name"] in written or not Path(bot["home"]).is_dir():
            continue
        try:
            _enable_bot_skills(Path(bot["home"]), plan["enabled_add"])
        except (Exception, ConfigBackendUnavailable):
            logger.warning("Could not enable the shared skills for %s ahead of the switch", bot["name"], exc_info=True)
            continue
        written.append(bot["name"])
    write_status(backup, manifest, STATUS_PREPARED, enabled_written=written)


def _write_bot_config(home: Path, bot_plan: dict) -> None:
    def edit(config: dict) -> dict[str, Any]:
        return {
            **skill_list_updates(config, enable=bot_plan["enabled_add"], disable_add=bot_plan["disabled_add"]),
            **_mcp_updates(config, bot_plan["mcp"]),
        }

    edit_config_keys(home / "config.yaml", edit)


def _remaining_files(root: Path) -> list[str]:
    found: list[str] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        base = Path(current)
        found += [(base / n).relative_to(root).as_posix() for n in files]
        found += [(base / n).relative_to(root).as_posix() for n in dirs if (base / n).is_symlink()]
    return sorted(found)


def _cleanup_bot(home: Path, backup_skills: Path, consumed: list[str]) -> list[str]:
    live_root = home / "skills"
    for rel in sorted(set(consumed)):
        live = live_root / rel
        if not (live.exists() or live.is_symlink()):
            continue
        if is_volatile(rel) or rel in REGENERABLE:
            remove_volatile(live)
        else:
            remove_matching(live, backup_skills / rel, rel, [])
        prune_empty_parents(live, live_root)
    return _remaining_files(live_root) if live_root.is_dir() else []


def _finish_bot(backup: Path, bot: dict, plan: dict, enabled_written: bool = False) -> tuple[list[str], list[str]]:
    home = Path(bot["home"])
    if enabled_written:
        plan = {**plan, "enabled_add": []}
    _write_bot_config(home, plan)
    changed = [f"{bot['name']}: updated {ref}" for ref in rewrite_references(home, plan["renames"])]
    return changed, _cleanup_bot(home, backup / bot["name"] / "skills", plan["consumed"])


def _finish(backup: Path, manifest: dict, say: Say, only: set[str] | None = None) -> None:
    from hermes_cli.config_backend import ConfigBackendUnavailable

    finished = set(manifest.get("finished_bots") or [])
    enabled_written = set(manifest.get("enabled_written") or [])
    bots = [b for b in manifest["bots"] if (only is None or b["name"] in only) and b["name"] not in finished]
    names = {b["name"] for b in bots}
    leftovers = {n: p for n, p in (manifest.get("leftovers") or {}).items() if n not in names}
    skipped = [n for n in (manifest.get("skipped_homes") or []) if n not in names]
    failed = {n: r for n, r in (manifest.get("failed_bots") or {}).items() if n not in names}
    changed: list[str] = []
    for bot in bots:
        plan = manifest["plan"].get(bot["name"])
        if plan is None or not Path(bot["home"]).is_dir():
            skipped.append(bot["name"])
            continue
        try:
            lines, left = _finish_bot(backup, bot, plan, bot["name"] in enabled_written)
        except (Exception, ConfigBackendUnavailable) as exc:
            logger.warning("Could not finish migrating %s", bot["name"], exc_info=True)
            failed[bot["name"]] = f"{type(exc).__name__}: {str(exc)[:200]}"
            continue
        finished.add(bot["name"])
        write_status(backup, manifest, manifest["status"], finished_bots=sorted(finished))
        changed += lines
        if left:
            leftovers[bot["name"]] = left
    write_status(backup, manifest, STATUS_COMMITTED, leftovers=leftovers, skipped_homes=skipped, failed_bots=failed,
                 finished_bots=sorted(finished))
    for line in changed:
        say(f"  {line}")
    for name, paths in leftovers.items():
        shown = ", ".join(paths[:_MAX_LISTED]) + (f", +{len(paths) - _MAX_LISTED} more" if len(paths) > _MAX_LISTED else "")
        say(f"  {name}: left {len(paths)} changed or unmigrated path(s) in place under its skills/ ({shown})")
    for name in skipped:
        say(f"  {name}: profile folder missing; skipped")
    for name, reason in failed.items():
        kept = ("its own skills are already enabled in the shared catalog, but its MCP settings, renamed references "
                "and old skill copies are not updated"
                if name in enabled_written else
                "its own skills may show as turned off and its MCP settings and old skill copies are not updated")
        say(f"  {name}: could not be switched to the shared catalog yet ({reason}); {kept} "
            "until you fix the cause and run `hermes catalog migrate --retry-failed`.")
    write_status(backup, manifest, STATUS_DONE)


def _rename_lines(plan: Plan) -> list[str]:
    lines = []
    for bot, bot_plan in sorted(plan.bots.items()):
        lines += [f"{bot}: skill {old} -> {new}" for old, new in sorted(bot_plan.renames.items())]
        lines += [f"{bot}: MCP server {old} -> {m['final']}" for old, m in sorted(bot_plan.mcp.items())
                  if m["final"] != old]
    return lines


def _describe(plan: Plan, say: Say) -> None:
    say(f"Catalog target: {catalog_dir()}")
    say(f"Skills: {len(plan.skills)} unique")
    for entry in plan.skills:
        owners = ", ".join(sorted(entry.owners))
        renamed = f" (renamed from {entry.key})" if entry.final_key != entry.key else ""
        say(f"  {entry.final_key}{renamed} [{entry.origin}]  <- {owners}")
    say(f"MCP servers: {len(plan.mcp)} unique")
    for entry in plan.mcp:
        owners = ", ".join(sorted(entry.owners))
        renamed = f" (renamed from {entry.name})" if entry.final_name != entry.name else ""
        say(f"  {entry.final_name}{renamed}  <- {owners}")
    for line in _rename_lines(plan):
        say(f"  rename {line}")
    for bot, bot_plan in plan.bots.items():
        say(f"  {bot}: {len(bot_plan.enabled_add)} catalog skill(s) enabled, {len(bot_plan.disabled_add)} bundled disabled")


def _remove_unpublished(manifest: dict) -> None:
    from hermes_cli.shared_catalog_rollback import remove_catalog_content

    remove_catalog_content(manifest)


def _commit(backup: Path, manifest: dict, say: Say) -> None:
    from utils import atomic_write_text

    sources = sources_from_backup(backup, manifest)
    plan = plan_migration(sources)
    manifest["catalog_digests"] = _publish_skills(plan)
    manifest["catalog_skills"] = [e.final_key for e in plan.skills]
    manifest["catalog_origins"] = _publish_origins(plan)
    manifest["catalog_files"] = _publish_skill_meta(sources, plan)
    manifest["catalog_carried"] = _carry_state(sources, plan)
    manifest["catalog_mcp"] = _publish_mcp(plan)
    manifest["plan"] = {bot: asdict(bot_plan) for bot, bot_plan in plan.bots.items()}
    manifest["renames"] = _rename_lines(plan)
    write_status(backup, manifest, STATUS_PREPARED)
    if problems := drift_since_backup(backup, manifest):
        raise MigrationDrift("Skills or settings changed while migrating, so nothing was switched over: "
                             + "; ".join(problems[:_MAX_LISTED]) + ". Run `hermes catalog migrate` again.")
    _enable_skills_before_marker(backup, manifest)
    atomic_write_text(catalog_dir() / CATALOG_MIGRATED_MARKER,
                      json.dumps({"backup": backup.name, "migrated": utc_stamp()}) + "\n")
    write_status(backup, manifest, STATUS_COMMITTED)
    say(f"Migrated {len(plan.skills)} skill(s) and {len(plan.mcp)} MCP server(s) into {catalog_dir()}")
    for line in manifest["renames"]:
        say(f"  renamed {line}")
    _finish(backup, manifest, say)
    say(f"Backup: {backup}")


def _prepare(say: Say) -> tuple[Path, dict]:
    resumable = newest_backup((STATUS_PREPARED,))
    if resumable is not None:
        backup, manifest = resumable
        problems = drift_since_backup(backup, manifest)
        if not problems:
            return resumable
        say("Skills or settings changed since the interrupted migration backup ("
            + "; ".join(problems[:_MAX_LISTED]) + "); taking a fresh backup.")
        _remove_unpublished(manifest)
        write_status(backup, manifest, STATUS_SUPERSEDED)
    return create_backup(discover_sources())


def migrate(*, dry_run: bool = False, retry_failed: bool = False, say: Say = print) -> int:
    if not dry_run:
        require_file_tooling("Shared catalog migration")
    with catalog_lock():
        if catalog_active():
            pending = newest_backup((STATUS_PREPARED, STATUS_COMMITTED))
            if pending is not None:
                say("Finishing an interrupted shared catalog migration.")
                _finish(*pending, say)
            elif retry_failed and (done := newest_backup((STATUS_DONE,))) is not None:
                if failed := set(done[1].get("failed_bots") or {}):
                    say("Retrying the bots that could not be switched over.")
                    _finish(*done, say, only=failed)
                    return 0
            say("Shared catalog already migrated; nothing to do.")
            return 0
        if dry_run:
            _describe(plan_migration(discover_sources()), say)
            return 0
        backup, manifest = _prepare(say)
        try:
            _commit(backup, manifest, say)
        except MigrationDrift as exc:
            say(str(exc))
            return 1
        return 0
