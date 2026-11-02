from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

import pytest
import hermes_yaml as yaml

from tests.e2e.core.bots._catalog import (
    FS,
    GH_ALICE,
    GH_BOB,
    NOTES,
    backups,
    catalog_markers,
    invisible,
    markers_by_bot,
    migrate,
    profile_state,
    secrets_digest,
    toggle,
    usable,
)
from tests.e2e.core.bots._world import (
    DEAD_URL,
    MARK_RE,
    World,
    allowed,
    denied,
    marker_for,
    tree_digest,
    write_skill,
)

@pytest.fixture
def world(tmp_path: Path) -> World:
    w = World(tmp_path)
    for name, spec in {
        "common": {},
        "only-default": {},
        "clash": {"marker": "MARK_CLASH_DEFAULT"},
    }.items():
        write_skill(w.default / "skills", name, **spec)
    w.add_bot(
        "alice",
        skills={
            "common": {},
            "clash": {"marker": "MARK_CLASH_ALICE"},
            "only-alice": {},
        },
        disabled=["common"],
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_ALICE), "notes": dict(NOTES)},
        tokens=["github"],
    )
    w.add_bot(
        "bob",
        skills={"common": {}, "only-bob": {}},
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_BOB)},
        tokens=["github"],
    )
    return w


@pytest.fixture
def shared_world(tmp_path: Path) -> World:
    w = World(tmp_path)
    w.add_bot("alice")
    w.add_bot("bob")
    w.enable_shared_layout()
    return w


def test_migrate_moves_skills_to_the_catalog_and_every_bot_keeps_exactly_its_enabled_skills(world: World) -> None:
    before = markers_by_bot(world)
    before_by_name = {bot: world.visible(bot) for bot in world.bots()}
    assert "MARK_CLASH_ALICE" in before["alice"] and "MARK_COMMON" not in before["alice"]

    migrate(world)

    assert (world.catalog / ".migrated").exists()
    assert len(backups(world)) == 1
    for bot in world.bots():
        leftovers = list((world.home_of(bot) / "skills").rglob("SKILL.md"))
        assert not leftovers, f"{bot} still owns skills after migration: {leftovers}"
    after = markers_by_bot(world)
    assert after == before, f"enabled skills changed per bot: before={before} after={after}"
    for bot in world.bots():
        now = world.visible(bot)
        for name, marks in before_by_name[bot].items():
            if not any("CLASH" in m for m in marks):
                assert now.get(name) == marks, f"{bot}: skill {name} changed or vanished"

    in_catalog = catalog_markers(world)
    assert [d for d, m in in_catalog.items() if m == {marker_for("common")}] == ["common"], "identical copies must merge into one"
    assert any(m == {"MARK_CLASH_DEFAULT"} for m in in_catalog.values())
    alice_clash = world.catalog / "skills" / "alice-clash" / "SKILL.md"
    assert alice_clash.exists(), f"conflicting skill not renamed <bot>-<skill>: {sorted(in_catalog)}"
    text = alice_clash.read_text(encoding="utf-8")
    front = yaml.safe_load(text.split("---")[1])
    assert front["name"] == "alice-clash" and "MARK_CLASH_ALICE" in text


def test_migrate_never_moves_tokens_and_leaves_them_byte_identical(world: World) -> None:
    before = secrets_digest(world)
    migrate(world)
    assert secrets_digest(world) == before
    for path in world.shared_root.rglob("*"):
        if path.is_file():
            body = path.read_text(encoding="utf-8", errors="ignore")
            assert "secret-" not in body and "refresh-" not in body and "tok-" not in body, f"credential leaked into {path}"
    assert not list(world.shared_root.rglob("mcp-tokens"))
    assert not list(world.shared_root.rglob("auth.json"))


def test_migrate_shares_mcp_definitions_and_keeps_per_bot_opt_in(world: World) -> None:
    migrate(world)
    shared = world.catalog_mcp()
    assert "shared-fs" in shared and shared["shared-fs"]["args"] == FS["args"]
    assert shared["notes"]["command"] == "npx"

    def github_for(bot: str, who: str) -> str:
        entries = world.config(bot).get("mcp_servers") or {}
        owned = [name for name in entries if name in shared and "gh-server" in " ".join(shared[name].get("args", []))]
        assert len(owned) == 1, f"{bot} should keep exactly one github opt-in, has {entries}"
        assert shared[owned[0]]["args"][-1] == who, f"{bot} opt-in resolves to someone else's github definition"
        return owned[0]

    alice_gh, bob_gh = github_for("alice", "alice"), github_for("bob", "bob")
    assert alice_gh != bob_gh, "conflicting definitions must not collapse into one name"

    for bot in ("alice", "bob"):
        entries = world.config(bot)["mcp_servers"]
        for name, entry in entries.items():
            assert set(entry) <= {"enabled"}, f"{bot}.{name} still carries a definition: {entry}"
    alice = world.config("alice")["mcp_servers"]
    assert alice["shared-fs"].get("enabled", True) is True
    assert alice["notes"]["enabled"] is False
    assert "notes" not in world.config("bob").get("mcp_servers", {})


def test_migrate_twice_is_a_no_op(world: World) -> None:
    migrate(world)
    snapshot = {bot: profile_state(world, bot) for bot in world.bots()}
    catalog = tree_digest(world.shared_root)
    migrate(world)
    assert {bot: profile_state(world, bot) for bot in world.bots()} == snapshot
    assert tree_digest(world.shared_root) == catalog


def test_rollback_restores_every_profile_byte_for_byte(world: World) -> None:
    before = {bot: profile_state(world, bot) for bot in world.bots()}
    migrate(world)
    assert (world.catalog / ".migrated").exists()
    migrate(world, "--rollback")
    assert not (world.catalog / ".migrated").exists()
    for bot in world.bots():
        after = profile_state(world, bot)
        assert after == before[bot], f"{bot} differs after rollback: " + str(
            sorted(k for k in set(before[bot]) | set(after) if before[bot].get(k) != after.get(k))[:10])


def test_a_skill_created_by_one_bot_is_on_only_for_that_bot_until_another_bot_turns_it_on(shared_world: World) -> None:
    created = shared_world.probe("alice", """
from tools.skill_manager_tool import skill_manage
content = "---\\nname: alice-made\\ndescription: Use when probing alice-made.\\n---\\n\\n# alice-made\\n\\nAlways follow MARK_ALICE_MADE.\\n"
emit(json.loads(skill_manage(action="create", name="alice-made", content=content)))
""")
    assert created.get("success"), created
    assert (shared_world.catalog / "skills" / "alice-made" / "SKILL.md").exists(), "created skill did not land in the shared catalog"
    assert not (shared_world.home_of("alice") / "skills" / "alice-made").exists()
    origins = json.loads((shared_world.catalog / "skills" / ".origins.json").read_text(encoding="utf-8"))
    assert origins["alice-made"] == {"origin": "bot", "owner": "alice"}
    assert shared_world.config("alice")["skills"]["enabled"] == ["alice-made"]

    alice = shared_world.surfaces("alice", ["alice-made"])["alice-made"]
    assert not usable(alice, "MARK_ALICE_MADE")
    for bot in ("bob", "default"):
        row = shared_world.surfaces(bot, ["alice-made"])["alice-made"]
        assert not invisible(row, "MARK_ALICE_MADE"), f"{bot} sees a skill it never turned on"

    toggle(shared_world, "bob", "alice-made", True)
    assert "alice-made" in shared_world.config("bob")["skills"]["enabled"]
    assert not usable(shared_world.surfaces("bob", ["alice-made"])["alice-made"], "MARK_ALICE_MADE")
    assert not invisible(shared_world.surfaces("default", ["alice-made"])["alice-made"], "MARK_ALICE_MADE")

    toggle(shared_world, "bob", "alice-made", False)
    assert "alice-made" not in (shared_world.config("bob").get("skills", {}).get("enabled") or [])
    assert not invisible(shared_world.surfaces("bob", ["alice-made"])["alice-made"], "MARK_ALICE_MADE")
    assert not usable(shared_world.surfaces("alice", ["alice-made"])["alice-made"], "MARK_ALICE_MADE")


def test_a_bundled_skill_is_on_for_every_bot_until_that_bot_disables_it_and_a_dropped_in_one_is_off_until_enabled(
    shared_world: World,
) -> None:
    shared_world.catalog_skill("dropped-in")
    shared_world.catalog_skill("shipped", bundled=True)
    shared_world.disable_skill("alice", "shipped")
    shared_world.enable_skill("bob", "dropped-in")
    assert "MARK_DROPPED_IN" in shared_world.visible_markers("bob")
    assert "MARK_DROPPED_IN" not in shared_world.visible_markers("default")
    assert "MARK_DROPPED_IN" not in shared_world.visible_markers("alice")
    assert "MARK_SHIPPED" in shared_world.visible_markers("bob")
    assert "MARK_SHIPPED" in shared_world.visible_markers("default")
    assert "MARK_SHIPPED" not in shared_world.visible_markers("alice")


def test_deleting_a_bot_leaves_the_catalog_untouched(shared_world: World) -> None:
    shared_world.catalog_skill("survivor", enabled_for=["bob"])
    catalog = tree_digest(shared_world.shared_root)
    proc = shared_world.hermes("default", "profile", "delete", "alice", "--yes")
    assert proc.returncode == 0, proc.stderr[-1500:]
    assert not shared_world.profile_exists("alice")
    assert tree_digest(shared_world.shared_root) == catalog
    assert "MARK_SURVIVOR" in shared_world.visible_markers("bob")
    assert catalog_markers(shared_world)["survivor"] == {"MARK_SURVIVOR"}


def test_shared_mcp_definitions_are_usable_only_by_bots_that_opt_in_and_vanish_for_everyone_when_removed(shared_world: World) -> None:
    shared_world.catalog_skill("docs-helper", connector="mcp:team-docs", enabled_for=["alice", "bob"])
    servers = shared_world.catalog_mcp()
    servers["team-docs"] = {"url": DEAD_URL}
    shared_world.save_catalog_mcp(servers)
    shared_world.set_mcp_enabled("alice", "team-docs", True)

    marker = marker_for("docs-helper")
    assert not allowed(shared_world.surfaces("alice", ["docs-helper"])["docs-helper"], marker)
    assert not denied(shared_world.surfaces("bob", ["docs-helper"])["docs-helper"], marker, "team-docs")

    shared_world.set_mcp_enabled("bob", "team-docs", False)
    assert not denied(shared_world.surfaces("bob", ["docs-helper"])["docs-helper"], marker, "team-docs")

    del servers["team-docs"]
    shared_world.save_catalog_mcp(servers)
    for bot in ("alice", "bob"):
        row = shared_world.surfaces(bot, ["docs-helper"])["docs-helper"]
        assert not denied(row, marker, "team-docs"), f"{bot} still connected to a removed definition"


def test_creating_a_bot_never_waits_on_the_catalog_lock_and_still_applies_its_opt_out(shared_world: World) -> None:
    holder = subprocess.Popen(
        [sys.executable, "-c",
         "import time\nfrom hermes_cli.shared_catalog import catalog_lock\n"
         "with catalog_lock():\n    print('held', flush=True)\n    time.sleep(40)"],
        cwd=str(shared_world.workdir), env=shared_world.env("default"), stdout=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == "held"
        started = time.monotonic()
        shared_world.hermes_ok("default", "profile", "create", "fresh", "--no-skills", "--no-alias", timeout=30)
        elapsed = time.monotonic() - started
    finally:
        holder.kill()
        holder.wait()
    assert elapsed < 20, f"profile create blocked on the catalog lock for {elapsed:.1f}s"
    disabled = (shared_world.config("fresh").get("skills") or {}).get("disabled") or []
    assert disabled, "a --no-skills bot must start with the bundled skills off"
