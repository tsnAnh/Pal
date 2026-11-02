from __future__ import annotations

import json
import os
import tarfile
from pathlib import Path

import pytest
import hermes_yaml as yaml

from tests.e2e.core.bots._catalog import FS, GH_ALICE, GH_BOB, backups, migrate, profile_state, toggle
from tests.e2e.core.bots._world import World, allowed, marker_for, tree_digest, write_skill

EFFECTIVE_SERVERS = """
from hermes_cli.config import read_user_config_raw
from hermes_cli.shared_catalog import effective_mcp_servers
cfg = read_user_config_raw()
emit({n: e for n, e in effective_mcp_servers(cfg.get("mcp_servers")).items()})
"""

CRON_JOBS = """
from cron import jobs
emit({j["name"]: j["skills"] for j in jobs.list_jobs(include_disabled=True)})
"""


@pytest.fixture
def world(tmp_path: Path) -> World:
    w = World(tmp_path)
    write_skill(w.default / "skills", "common")
    write_skill(w.default / "skills", "clash", marker="MARK_CLASH_DEFAULT")
    w.add_bot(
        "alice",
        skills={"common": {}, "clash": {"marker": "MARK_CLASH_ALICE"}, "only-alice": {}},
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_ALICE)},
        tokens=["github"],
    )
    w.add_bot(
        "bob",
        skills={"common": {}, "only-bob": {}},
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_BOB)},
    )
    return w


def manifest_of(backup: Path) -> dict:
    return json.loads((backup / "manifest.json").read_text(encoding="utf-8"))


def effective(w: World, bot: str) -> dict:
    return w.probe(bot, EFFECTIVE_SERVERS)


def every_server_has_a_transport(w: World) -> None:
    for bot in w.bots():
        servers = effective(w, bot)
        for name, entry in servers.items():
            assert "command" in entry or "url" in entry, f"{bot}.{name} has no transport: {entry}"


def catalog_names(w: World) -> dict[str, str]:
    out = {}
    for md in (w.catalog / "skills").rglob("SKILL.md"):
        front = yaml.safe_load(md.read_text(encoding="utf-8").split("---")[1])
        out[md.parent.relative_to(w.catalog / "skills").as_posix()] = front["name"]
    return out


def test_a_skill_written_after_the_backup_is_migrated_not_destroyed_and_stale_settings_are_not_replayed(world: World) -> None:
    world.probe("default", """
from hermes_cli.shared_catalog_backup import create_backup, discover_sources
backup, _ = create_backup(discover_sources())
emit({"backup": backup.name})
""")
    write_skill(world.home_of("alice") / "skills", "late-skill")
    world.disable_skill("alice", "only-alice")
    world.update_config("alice", {"mcp_servers": {"later": {"command": "npx", "args": ["-y", "later-server"]}}})

    migrate(world)

    first, second = backups(world)
    assert manifest_of(first)["status"] == "superseded"
    assert manifest_of(second)["status"] == "done"
    assert "MARK_LATE_SKILL" in world.visible_markers("alice"), "a skill written after the backup was lost"
    assert "MARK_ONLY_ALICE" not in world.visible_markers("alice"), "a stale plan re-enabled a skill the bot had since disabled"
    assert world.catalog_mcp()["later"]["args"] == ["-y", "later-server"]
    assert "command" not in world.config("alice")["mcp_servers"]["later"]
    every_server_has_a_transport(world)


def test_a_write_that_races_the_cleanup_is_left_in_place_and_reported(world: World) -> None:
    result = world.probe("default", """
import os
from pathlib import Path
import hermes_cli.shared_catalog_migrate as m

home = Path(os.environ["ALICE_HOME"])
real = m.rewrite_references

def racing(target, renames):
    if target == home:
        (home / "skills" / "only-alice" / "SKILL.md").write_text("---\\nname: only-alice\\ndescription: x\\n---\\nEDITED_AFTER_BACKUP\\n", encoding="utf-8")
        late = home / "skills" / "raced"
        late.mkdir()
        (late / "SKILL.md").write_text("---\\nname: raced\\ndescription: x\\n---\\nRACED\\n", encoding="utf-8")
    return real(target, renames)

m.rewrite_references = racing
lines = []
emit({"rc": m.migrate(say=lines.append), "lines": lines})
""", {"ALICE_HOME": str(world.home_of("alice"))})
    assert result["rc"] == 0
    alice_skills = world.home_of("alice") / "skills"
    assert "EDITED_AFTER_BACKUP" in (alice_skills / "only-alice" / "SKILL.md").read_text(encoding="utf-8")
    assert (alice_skills / "raced" / "SKILL.md").exists()
    assert not (alice_skills / "common").exists(), "an unchanged migrated skill must still be cleaned up"
    assert any("left" in line and "alice" in line for line in result["lines"]), result["lines"]


def test_non_skill_content_survives_migration_and_comes_back_on_rollback(world: World, tmp_path: Path) -> None:
    alice_skills = world.home_of("alice") / "skills"
    bob_skills = world.home_of("bob") / "skills"
    write_skill(alice_skills / ".archive", "retired")
    (alice_skills / ".curator_backups" / "20260101T000000Z").mkdir(parents=True)
    (alice_skills / ".curator_backups" / "20260101T000000Z" / "skills.tar.gz").write_bytes(b"alice-backup")
    (alice_skills / ".hub").mkdir()
    (alice_skills / ".hub" / "taps.json").write_text(json.dumps({"taps": [{"repo": "alice/skills"}]}), encoding="utf-8")
    (alice_skills / ".hub" / "audit.log").write_text("alice installed x\n", encoding="utf-8")
    write_skill(alice_skills / ".hub" / "quarantine", "held")
    (alice_skills / "notes.txt").write_text("keep me", encoding="utf-8")
    (alice_skills / "legacy-note.md").write_text("---\nname: legacy-note\ndescription: legacy\n---\nMARK_LEGACY\n", encoding="utf-8")
    external = tmp_path / "external" / "linked-skill"
    write_skill(external.parent, "linked-skill")
    os.symlink(external, alice_skills / "linked-skill")
    (bob_skills / ".hub").mkdir()
    (bob_skills / ".hub" / "taps.json").write_text(json.dumps({"taps": [{"repo": "bob/skills"}]}), encoding="utf-8")
    (bob_skills / ".hub" / "audit.log").write_text("bob installed y\n", encoding="utf-8")
    before = {"alice": tree_digest(alice_skills), "bob": tree_digest(bob_skills)}

    out = world.hermes_ok("default", "catalog", "migrate").stdout

    catalog = world.catalog / "skills"
    assert (catalog / ".archive" / "retired" / "SKILL.md").exists()
    assert (catalog / ".curator_backups" / "20260101T000000Z" / "skills.tar.gz").read_bytes() == b"alice-backup"
    assert (catalog / ".hub" / "quarantine" / "held" / "SKILL.md").exists()
    taps = json.loads((catalog / ".hub" / "taps.json").read_text(encoding="utf-8"))["taps"]
    assert {t["repo"] for t in taps} == {"alice/skills", "bob/skills"}
    audit = (catalog / ".hub" / "audit.log").read_text(encoding="utf-8")
    assert "alice installed x" in audit and "bob installed y" in audit
    assert (catalog / "legacy-note.md").exists()
    assert (catalog / "linked-skill").is_symlink() and Path(os.readlink(catalog / "linked-skill")) == external
    assert external.joinpath("SKILL.md").exists(), "migration must never touch a symlink target"
    assert (alice_skills / "notes.txt").read_text(encoding="utf-8") == "keep me"
    assert "notes.txt" in out and "left" in out, out
    assert not (alice_skills / ".archive").exists() and not (alice_skills / "linked-skill").is_symlink()
    assert "MARK_LINKED_SKILL" in world.visible_markers("alice")
    assert "MARK_LINKED_SKILL" not in world.visible_markers("bob")
    legacy = {bot: world.surfaces(bot, ["legacy-note"])["legacy-note"]["view"] for bot in ("alice", "bob")}
    assert legacy["alice"].get("success") and "MARK_LEGACY" in legacy["alice"]["content"], legacy["alice"]
    assert legacy["bob"].get("success") is False, "a flat legacy skill must stay off for bots that never had it"

    migrate(world, "--rollback")

    after = tree_digest(alice_skills)
    missing = sorted(k for k in before["alice"] if after.get(k) != before["alice"][k] and not k.endswith("/"))
    assert not missing, f"rollback did not restore: {missing[:10]}"
    assert Path(os.readlink(alice_skills / "linked-skill")) == external
    assert tree_digest(bob_skills) == before["bob"]


def test_a_crash_before_the_marker_or_midway_through_the_stub_rewrites_never_strands_a_bot_without_its_servers(world: World) -> None:
    crashed = world.probe("default", """
import hermes_cli.shared_catalog_migrate as m

def crash(*args, **kwargs):
    raise RuntimeError("power loss")

m.drift_since_backup = crash
try:
    m.migrate(say=lambda line: None)
except RuntimeError as exc:
    emit({"crashed": str(exc)})
""")
    assert crashed["crashed"] == "power loss"
    assert not (world.catalog / ".migrated").exists()
    every_server_has_a_transport(world)
    assert "command" in world.config("alice")["mcp_servers"]["shared-fs"]

    halfway = world.probe("default", """
import hermes_cli.shared_catalog_migrate as m

calls = {"n": 0}
real = m._write_bot_config

def flaky(home, plan):
    calls["n"] += 1
    if calls["n"] == 3:
        raise KeyboardInterrupt("power loss")
    return real(home, plan)

m._write_bot_config = flaky
try:
    m.migrate(say=lambda line: None)
except KeyboardInterrupt as exc:
    emit({"crashed": str(exc)})
""")
    assert halfway["crashed"] == "power loss"
    assert (world.catalog / ".migrated").exists()
    stubbed = [bot for bot in world.bots() if "command" not in world.config(bot).get("mcp_servers", {}).get("shared-fs", {"command": 1})]
    assert stubbed, "the crash should have left at least one bot already rewritten"
    every_server_has_a_transport(world)
    assert effective(world, "alice")["shared-fs"]["args"] == FS["args"]

    out = world.hermes_ok("default", "catalog", "migrate").stdout
    assert "Finishing an interrupted" in out
    for bot in world.bots():
        for entry in world.config(bot).get("mcp_servers", {}).values():
            assert "command" not in entry
    every_server_has_a_transport(world)
    assert manifest_of(backups(world)[-1])["status"] == "done"


def test_rollback_with_a_deleted_profile_keeps_later_edits_and_finishes_on_retry(world: World) -> None:
    migrate(world)
    world.update_config("alice", {"memory": {"nudge_interval": 7}})
    created = world.probe("alice", """
from tools.skill_manager_tool import skill_manage
content = "---\\nname: post-skill\\ndescription: Use when probing post-skill.\\n---\\n\\n# post-skill\\n\\nAlways follow MARK_POST_SKILL.\\n"
emit(json.loads(skill_manage(action="create", name="post-skill", content=content)))
""")
    assert created.get("success"), created
    world.hermes_ok("default", "profile", "create", "fresh", "--no-alias", "--no-skills")
    world.update_config("fresh", {"mcp_servers": {"shared-fs": {"enabled": True}}})
    world.hermes_ok("default", "profile", "delete", "bob", "--yes")
    assert not world.profile_exists("bob")

    crashed = world.probe("default", """
import hermes_cli.shared_catalog_rollback as r

def boom(*args, **kwargs):
    raise RuntimeError("disk full")

r._preserve_edited = boom
try:
    r.rollback(say=lambda line: None)
except RuntimeError as exc:
    emit({"crashed": str(exc)})
""")
    assert crashed["crashed"] == "disk full"
    assert (world.catalog / ".migrated").exists(), "the marker must go last"
    assert manifest_of(backups(world)[-1])["status"] == "rolling-back"

    migrate(world, "--rollback")

    assert not (world.catalog / ".migrated").exists()
    manifest = manifest_of(backups(world)[-1])
    assert manifest["status"] == "rolled-back" and manifest["rollback_skipped"] == ["bob"]
    alice = world.config("alice")
    assert alice["memory"]["nudge_interval"] == 7, "a config edit made after the migration was wiped"
    assert "enabled" not in alice.get("skills", {})
    assert alice["mcp_servers"]["shared-fs"]["args"] == FS["args"]
    assert (world.home_of("alice") / "skills" / "only-alice" / "SKILL.md").exists()
    assert (world.home_of("alice") / "skills" / "post-skill" / "SKILL.md").exists(), "a skill created after the migration was orphaned"
    assert "MARK_POST_SKILL" in world.visible_markers("alice")
    fresh_fs = world.config("fresh")["mcp_servers"]["shared-fs"]
    assert fresh_fs["args"] == FS["args"] and fresh_fs["command"] == "npx", "a profile made after the migration kept a transport-less stub"

    migrate(world)
    assert (world.catalog / ".migrated").exists()
    assert "MARK_POST_SKILL" in world.visible_markers("alice")


def test_config_comments_survive_migration_and_rollback(world: World) -> None:
    path = world.home_of("alice") / "config.yaml"
    text = path.read_text(encoding="utf-8")
    text = "# keep this note about my bot\n" + text.replace(
        "mcp_servers:", "terminal:\n  # and this one\n  timeout: 99  # seconds\nmcp_servers:", 1)
    path.write_text(text, encoding="utf-8")

    def comments_survive() -> None:
        now = path.read_text(encoding="utf-8")
        assert "# keep this note about my bot" in now and "# and this one" in now and "# seconds" in now

    migrate(world)
    comments_survive()
    migrate(world, "--rollback")
    comments_survive()
    assert world.config("alice")["terminal"]["timeout"] == 99


def test_migration_records_origins_and_each_bot_keeps_only_what_it_had(world: World) -> None:
    migrate(world)
    origins = json.loads((world.catalog / "skills" / ".origins.json").read_text(encoding="utf-8"))
    assert origins["only-bob"] == {"origin": "migrated", "owner": "bob"}
    assert origins["common"]["origin"] == "migrated" and set(origins["common"]["owners"]) == {"default", "alice", "bob"}
    assert "only-bob" in world.config("bob")["skills"]["enabled"]
    assert "only-bob" not in (world.config("alice").get("skills", {}).get("enabled") or [])
    assert "MARK_ONLY_BOB" in world.visible_markers("bob")
    assert "MARK_ONLY_BOB" not in world.visible_markers("alice")
    assert "MARK_ONLY_BOB" not in world.visible_markers("default")


def test_the_curator_only_touches_the_running_bots_own_skills_and_bundled_ones_it_has_enabled(tmp_path: Path) -> None:
    w = World(tmp_path)
    w.add_bot("alice", extra={"curator": {"prune_builtins": True}})
    w.add_bot("bob", extra={"curator": {"prune_builtins": True}})
    w.enable_shared_layout()
    w.catalog_skill("shipped", bundled=True)
    w.disable_skill("bob", "shipped")
    snippet = """
import os
from tools.skill_manager_tool import skill_manage
from tools import skill_usage
name = os.environ["MADE"]
content = f"---\\nname: {name}\\ndescription: Use when probing {name}.\\n---\\n\\n# {name}\\n"
skill_manage(action="create", name=name, content=content)
skill_usage.mark_agent_created(name)
emit({})
"""
    w.probe("alice", snippet, {"MADE": "alice-note"})
    w.probe("bob", snippet, {"MADE": "bob-note"})
    scope = """
from tools import skill_usage
emit({
    "managed": skill_usage.list_agent_created_skill_names(),
    "eligible": {n: skill_usage.is_curation_eligible(n) for n in ("alice-note", "bob-note", "shipped")},
})
"""
    alice = w.probe("alice", scope)
    bob = w.probe("bob", scope)
    assert "alice-note" in alice["managed"] and "bob-note" not in alice["managed"]
    assert "bob-note" in bob["managed"] and "alice-note" not in bob["managed"]
    assert alice["eligible"] == {"alice-note": True, "bob-note": False, "shipped": True}
    assert bob["eligible"] == {"alice-note": False, "bob-note": True, "shipped": False}


def test_a_renaming_bots_own_references_follow_its_renamed_skill_and_category_twins_stay_apart(world: World) -> None:
    write_skill(world.home_of("alice") / "skills" / "x", "foo", marker="MARK_FOO_ALICE")
    write_skill(world.home_of("bob") / "skills" / "y", "foo", marker="MARK_FOO_BOB")
    world.update_config("alice", {
        "skills": {"auto_load": ["clash", "common"]},
        "discord": {"channel_skill_bindings": [{"id": "1", "skills": ["clash"]}, {"id": "2", "skill": "clash"}]},
    })
    create_job = """
from cron import jobs
jobs.create_job("do it", "every 1h", name="nightly", skills=["clash"])
emit({})
"""
    world.probe("alice", create_job)
    world.probe("default", create_job)

    out = world.hermes_ok("default", "catalog", "migrate").stdout

    assert "alice: skill clash -> alice-clash" in out, out
    alice = world.config("alice")
    assert alice["skills"]["auto_load"] == ["alice-clash", "common"]
    assert alice["discord"]["channel_skill_bindings"] == [
        {"id": "1", "skills": ["alice-clash"]}, {"id": "2", "skill": "alice-clash"}]
    assert world.probe("alice", CRON_JOBS) == {"nightly": ["alice-clash"]}
    assert world.probe("default", CRON_JOBS) == {"nightly": ["clash"]}
    assert not allowed(world.surfaces("alice", ["alice-clash"])["alice-clash"], "MARK_CLASH_ALICE")

    names = catalog_names(world)
    assert len(set(names.values())) == len(names), f"two catalog skills share a name: {names}"
    assert "MARK_FOO_ALICE" in world.visible_markers("alice") and "MARK_FOO_BOB" not in world.visible_markers("alice")
    assert "MARK_FOO_BOB" in world.visible_markers("bob") and "MARK_FOO_ALICE" not in world.visible_markers("bob")


def read_archive(path: Path) -> dict[str, bytes]:
    with tarfile.open(path) as archive:
        return {m.name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}


def test_exporting_a_migrated_bot_carries_its_skills_and_servers_into_a_fresh_install(world: World, tmp_path: Path) -> None:
    migrate(world)
    identity = world.home_of("alice") / "identity-history"
    identity.mkdir()
    (identity / "0001.json").write_text('{"private": true}', encoding="utf-8")
    archive = tmp_path / "alice.tar.gz"

    world.hermes_ok("default", "profile", "export", "alice", "-o", str(archive))

    members = read_archive(archive)
    assert "alice/skills/only-alice/SKILL.md" in members and "alice/skills/alice-clash/SKILL.md" in members
    assert not any("identity-history" in name for name in members)
    exported = yaml.safe_load(members["alice/config.yaml"].decode("utf-8"))
    assert exported["mcp_servers"]["shared-fs"]["command"] == "npx"
    assert exported["mcp_servers"]["github"]["args"][-1] == "alice"

    fresh = World(tmp_path / "fresh-install")
    fresh.enable_shared_layout()
    fresh.hermes_ok("default", "profile", "import", str(archive), "--name", "alice2")

    imported = fresh.home_of("alice2")
    assert not list((imported / "skills").rglob("SKILL.md")), "imported skills must live in the shared catalog"
    assert (fresh.catalog / "skills" / "only-alice" / "SKILL.md").exists()
    origins = json.loads((fresh.catalog / "skills" / ".origins.json").read_text(encoding="utf-8"))
    assert origins["only-alice"] == {"origin": "bot", "owner": "alice2"}
    assert "only-alice" in fresh.config("alice2")["skills"]["enabled"]
    assert "MARK_ONLY_ALICE" in fresh.visible_markers("alice2")
    assert "MARK_ONLY_ALICE" not in fresh.visible_markers("default")
    servers = effective(fresh, "alice2")
    assert servers["shared-fs"]["command"] == "npx" and servers["github"]["args"][-1] == "alice"
    assert not (imported / "identity-history").exists()

    plain = World(tmp_path / "plain-install")
    plain.hermes_ok("default", "profile", "import", str(archive), "--name", "alice3")
    assert (plain.home_of("alice3") / "skills" / "only-alice" / "SKILL.md").exists()


def test_a_template_of_a_migrated_bot_round_trips_its_own_skills_and_servers(world: World, tmp_path: Path) -> None:
    migrate(world)
    template = tmp_path / "alice.hermesbot"
    world.probe("alice", """
import os
from pathlib import Path
from hermes_cli.bot_template import export_template
Path(os.environ["OUT"]).write_bytes(export_template("alice"))
emit({})
""", {"OUT": str(template)})

    members = read_archive(template)
    assert "skills/only-alice/SKILL.md" in members
    assert "skills/common/SKILL.md" in members and not any("identity-history" in name for name in members)
    bot = json.loads(members["bot.json"].decode("utf-8"))
    assert bot["config"]["mcp_servers"]["shared-fs"]["command"] == "npx"

    fresh = World(tmp_path / "fresh-install")
    fresh.enable_shared_layout()
    imported = fresh.probe("default", """
import os
from pathlib import Path
from hermes_cli.bot_template import import_template, inspect_template
data = Path(os.environ["SRC"]).read_bytes()
emit(import_template(data, reviewed_digest=inspect_template(data)["digest"], name="clone"))
""", {"SRC": str(template)})

    assert imported["skills_imported"] >= 1
    assert (fresh.catalog / "skills" / "only-alice" / "SKILL.md").exists()
    assert "only-alice" in fresh.config("clone")["skills"]["enabled"]
    assert "MARK_ONLY_ALICE" in fresh.visible_markers("clone")
    assert "MARK_ONLY_ALICE" not in fresh.visible_markers("default")
    assert "shared-fs" in fresh.config("clone")["mcp_servers"]


def test_a_second_migration_attempt_after_a_clean_rollback_matches_the_first(world: World) -> None:
    before = {bot: profile_state(world, bot) for bot in world.bots()}
    migrate(world)
    migrate(world, "--rollback")
    migrate(world)
    assert marker_for("only-alice") in world.visible_markers("alice")
    assert len(backups(world)) == 2
    migrate(world, "--rollback")
    for bot in world.bots():
        assert {k: v for k, v in profile_state(world, bot).items() if k.startswith("skills/")} == {
            k: v for k, v in before[bot].items() if k.startswith("skills/")}


def test_the_dry_run_reports_renames_without_changing_anything(world: World) -> None:
    before = {bot: profile_state(world, bot) for bot in world.bots()}
    out = world.hermes_ok("default", "catalog", "migrate", "--dry-run").stdout
    assert "rename alice: skill clash -> alice-clash" in out, out
    assert {bot: profile_state(world, bot) for bot in world.bots()} == before
    assert not (world.catalog / ".migrated").exists()


def test_a_new_profile_gets_the_bundled_skills_but_none_of_the_other_bots_skills(tmp_path: Path) -> None:
    w = World(tmp_path)
    w.add_bot("alice")
    w.enable_shared_layout()
    w.catalog_skill("shipped", bundled=True)
    w.catalog_skill("alice-only", enabled_for=["alice"])
    w.hermes_ok("default", "profile", "create", "fresh", "--no-alias")
    assert w.visible_markers("fresh") == {"MARK_SHIPPED"}
    assert w.visible_markers("alice") == {"MARK_SHIPPED", "MARK_ALICE_ONLY"}


FAIL_ALICE_SWITCH_OVER = """
import os
from pathlib import Path
import hermes_cli.shared_catalog_migrate as m

real = m._write_bot_config
alice = Path(os.environ["ALICE_HOME"])

def flaky(home, plan):
    if home == alice:
        raise RuntimeError("disk full")
    return real(home, plan)

m._write_bot_config = flaky
lines = []
emit({"rc": m.migrate(say=lines.append), "lines": lines})
"""


def test_a_bot_whose_switch_over_failed_keeps_its_own_skills_enabled_and_is_told_what_is_still_pending(world: World) -> None:
    result = world.probe("default", FAIL_ALICE_SWITCH_OVER, {"ALICE_HOME": str(world.home_of("alice"))})

    assert result["rc"] == 0
    assert (world.catalog / ".migrated").exists()
    assert set(manifest_of(backups(world)[-1])["failed_bots"]) == {"alice"}
    assert "only-alice" in world.config("alice")["skills"]["enabled"]
    assert "MARK_ONLY_ALICE" in world.visible_markers("alice")
    reported = "\n".join(result["lines"])
    assert "stay in its own folder" not in reported
    assert "already enabled in the shared catalog" in reported


def test_a_retry_that_crashes_between_its_status_writes_never_turns_a_re_enabled_bundled_skill_off_again(tmp_path: Path) -> None:
    w = World(tmp_path)
    w.add_bot("alice", skills={"shipped": {}, "only-alice": {}})
    (w.home_of("alice") / "skills" / ".bundled_manifest").write_text("shipped:e2e\n", encoding="utf-8")
    w.add_bot("bob", skills={"only-bob": {}})

    first = w.probe("default", FAIL_ALICE_SWITCH_OVER, {"ALICE_HOME": str(w.home_of("alice"))})
    assert first["rc"] == 0
    assert "shipped" in w.config("bob")["skills"]["disabled"]

    cfg = w.config("bob")
    cfg["skills"]["disabled"] = [n for n in cfg["skills"]["disabled"] if n != "shipped"]
    w.save_config("bob", cfg)

    crashed = w.probe("default", """
import hermes_cli.shared_catalog_migrate as m

real = m.write_status
seen = []

def crashing(backup, manifest, status, **extra):
    if status == m.STATUS_DONE and m.STATUS_COMMITTED in seen:
        raise KeyboardInterrupt("power loss")
    seen.append(status)
    return real(backup, manifest, status, **extra)

m.write_status = crashing
try:
    m.migrate(retry_failed=True, say=lambda line: None)
except KeyboardInterrupt as exc:
    emit({"crashed": str(exc)})
""")
    assert crashed["crashed"] == "power loss"
    assert manifest_of(backups(w)[-1])["status"] == "committed"

    out = w.hermes_ok("default", "catalog", "migrate").stdout

    assert "Finishing an interrupted" in out
    assert "shipped" not in w.config("bob")["skills"].get("disabled", [])
    assert manifest_of(backups(w)[-1])["status"] == "done"


def test_an_update_carries_on_past_a_bot_whose_config_backend_is_unavailable(world: World) -> None:
    migrate(world)

    result = world.probe("default", """
import contextlib, io
from hermes_cli.config_backend import ConfigBackendUnavailable
import hermes_cli.profiles as profiles
import hermes_cli.shared_catalog as catalog
import hermes_cli.update_cmd_maint as maint

real = catalog.apply_bundled_opt_out
reached = []

def refuse_alice(path, names):
    if path.name == "alice":
        raise ConfigBackendUnavailable("no config file backend")
    reached.append(path.name)
    return real(path, names)

def backfill(quiet=False):
    reached.append("backfill")
    return []

catalog.apply_bundled_opt_out = refuse_alice
profiles.backfill_profile_envs = backfill
out = io.StringIO()
with contextlib.redirect_stdout(out):
    maint._sync_profiles_after_update()
emit({"out": out.getvalue(), "reached": reached})
""")

    assert "alice: no config file backend" in result["out"]
    assert "bob: shared" in result["out"]
    assert result["reached"] == ["bob", "backfill"]


def test_sandbox_mounts_and_file_sync_agree_on_symlinked_and_flat_catalog_skills(world: World, tmp_path: Path) -> None:
    migrate(world)
    skills = world.catalog / "skills"
    outside = tmp_path / "outside-skill"
    write_skill(tmp_path, "outside-skill")
    (skills / "linked-skill").symlink_to(outside, target_is_directory=True)
    (skills / "flat-note.md").write_text("---\nname: flat-note\ndescription: flat\n---\nFLAT\n", encoding="utf-8")
    world.enable_skill("alice", "linked-skill")
    world.enable_skill("alice", "flat-note")

    seen = world.probe("alice", """
from tools.credential_files import get_skills_directory_mount, iter_skills_files
emit({
    "mounts": sorted(m["container_path"] for m in get_skills_directory_mount()),
    "files": sorted(m["container_path"] for m in iter_skills_files()),
})
""")

    assert not [p for p in seen["mounts"] + seen["files"] if "linked-skill" in p], seen
    assert "/root/.hermes/skills/flat-note.md" in seen["mounts"], seen
    assert "/root/.hermes/skills/flat-note.md" in seen["files"], seen
