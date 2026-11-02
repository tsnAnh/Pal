from __future__ import annotations

import json
from pathlib import Path

from tests.e2e.core.bots._world import MARK_RE, World, tree_digest

GH_ALICE = {"command": "npx", "args": ["-y", "gh-server", "--who", "alice"]}
GH_BOB = {"command": "npx", "args": ["-y", "gh-server", "--who", "bob"]}
FS = {"command": "npx", "args": ["-y", "fs-server"]}
NOTES = {"command": "npx", "args": ["-y", "notes-server"], "enabled": False}


def markers_by_bot(w: World) -> dict[str, set[str]]:
    return {bot: w.visible_markers(bot) for bot in w.bots()}


def secrets_digest(w: World) -> dict[str, dict[str, str]]:
    out = {}
    for bot in w.bots():
        home = w.home_of(bot)
        top = tree_digest(home)
        digest = {".env": top.get(".env", ""), "auth.json": top.get("auth.json", "")}
        digest.update({f"mcp-tokens/{k}": v for k, v in tree_digest(home / "mcp-tokens").items()})
        out[bot] = digest
    return out


def catalog_markers(w: World) -> dict[str, set[str]]:
    found = {}
    for md in (w.catalog / "skills").glob("*/SKILL.md"):
        found[md.parent.name] = set(MARK_RE.findall(md.read_text(encoding="utf-8")))
    return found


def profile_state(w: World, bot: str) -> dict[str, str]:
    home = w.home_of(bot)
    out: dict[str, str] = {}
    for part in ("skills", "config.yaml", ".env", "auth.json", "mcp-tokens"):
        target = home / part
        if target.is_dir():
            out.update({f"{part}/{k}": v for k, v in tree_digest(target).items()})
        elif target.exists():
            out[part] = tree_digest(home)[part]
    return out


def backups(w: World) -> list[Path]:
    return sorted(w.shared_root.glob("migration-backup-*"))


def migrate(w: World, *extra: str) -> None:
    w.hermes_ok("default", "catalog", "migrate", *extra)


def invisible(row: dict, marker: str) -> list[str]:
    problems = []
    if row["listed"] or row["indexed"]:
        problems.append("listed or indexed")
    if row["view"].get("success") is not False or row["view_file"].get("success") is not False:
        problems.append("skill_view succeeded")
    for key in ("view", "view_file", "slash", "cron"):
        if marker in json.dumps(row[key]):
            problems.append(f"{key} leaked the skill body")
    return problems


def usable(row: dict, marker: str) -> list[str]:
    problems = []
    if not (row["listed"] and row["indexed"]):
        problems.append("not listed or not indexed")
    if not row["view"].get("success") or marker not in str(row["view"].get("content", "")):
        problems.append(f"skill_view denied: {str(row['view'])[:200]}")
    if marker not in row["slash"] or marker not in row["cron"]:
        problems.append("slash or cron did not load it")
    return problems


def toggle(w: World, bot: str, name: str, enabled: bool) -> None:
    w.probe(bot, """
import asyncio, os
from hermes_cli.web_models import SkillToggle
from hermes_cli.web_routers.skills import toggle_skill
emit(asyncio.run(toggle_skill(SkillToggle(name=os.environ["T_NAME"], enabled=os.environ["T_ON"] == "1"), profile=None)))
""", {"T_NAME": name, "T_ON": "1" if enabled else "0"})
