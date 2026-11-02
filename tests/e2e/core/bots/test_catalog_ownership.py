from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.e2e.core.bots._catalog import FS, GH_ALICE, GH_BOB, backups, migrate, usable
from tests.e2e.core.bots._world import World, write_skill

SHARED_REFUSAL = "This skill is shared with other bots, so I can't change it. I can create my own copy under a new name."

CREATE = """
import os
from tools.skill_manager_tool import skill_manage
name = os.environ["MADE"]
content = f"---\\nname: {name}\\ndescription: Use when probing {name}.\\n---\\n\\n# {name}\\n\\nAlways follow MARK_{name.upper().replace('-', '_')}.\\n"
emit(json.loads(skill_manage(action="create", name=name, content=content)))
"""

WRITES = """
import json, os
from tools.skill_manager_tool import skill_manage

name = os.environ["TARGET"]
rows = {
    "patch": skill_manage(action="patch", name=name, old_string="Always follow", new_string="Never follow"),
    "write_file": skill_manage(action="write_file", name=name, file_path="references/extra.md", file_content="extra"),
    "remove_file": skill_manage(action="remove_file", name=name, file_path="references/notes.md"),
    "edit": skill_manage(action="edit", name=name, content="---\\nname: " + name + "\\ndescription: x\\n---\\nREWRITTEN\\n"),
    "batch": skill_manage(action="patch", name=name, operations=[
        {"action": "patch", "name": name, "old_string": "Always follow", "new_string": "Never follow"}]),
    "delete": skill_manage(action="delete", name=name),
}
emit({k: json.loads(v) for k, v in rows.items()})
"""

OWN_EDIT = """
import os
from tools.skill_manager_tool import skill_manage

name = os.environ["TARGET"]
patched = json.loads(skill_manage(action="patch", name=name, old_string="Always follow", new_string="Always honor"))
wrote = json.loads(skill_manage(action="write_file", name=name, file_path="references/extra.md", file_content="extra"))
emit({"patched": patched, "wrote": wrote})
"""


@pytest.fixture
def shared_world(tmp_path: Path) -> World:
    w = World(tmp_path)
    w.add_bot("alice")
    w.add_bot("bob")
    w.enable_shared_layout()
    return w


def origins_of(w: World) -> dict:
    return json.loads((w.catalog / "skills" / ".origins.json").read_text(encoding="utf-8"))


def skill_text(w: World, name: str) -> str:
    return (w.catalog / "skills" / name / "SKILL.md").read_text(encoding="utf-8")


def test_a_bot_cannot_change_or_delete_skills_it_does_not_own_but_can_edit_its_own(shared_world: World) -> None:
    w = shared_world
    assert w.probe("bob", CREATE, {"MADE": "bob-made"}).get("success")
    w.catalog_skill("shipped", bundled=True)
    w.probe("alice", CREATE, {"MADE": "alice-made"})
    before = {name: skill_text(w, name) for name in ("bob-made", "shipped", "alice-made")}

    for target in ("bob-made", "shipped"):
        rows = w.probe("alice", WRITES, {"TARGET": target})
        for action, row in rows.items():
            assert row.get("success") is False, f"alice could {action} {target}: {row}"
            assert SHARED_REFUSAL in json.dumps(row), f"{action} on {target}: {row}"
        assert skill_text(w, target) == before[target], f"{target} changed"

    assert (w.catalog / "skills" / "bob-made").is_dir() and (w.catalog / "skills" / "shipped").is_dir()

    own = w.probe("alice", OWN_EDIT, {"TARGET": "alice-made"})
    assert own["patched"].get("success") and own["wrote"].get("success"), own
    assert "Always honor" in skill_text(w, "alice-made")

    bob_view = w.probe("bob", OWN_EDIT, {"TARGET": "alice-made"})
    assert bob_view["patched"].get("success") is False and SHARED_REFUSAL in json.dumps(bob_view["patched"])


def test_a_human_editing_through_the_dashboard_can_still_change_a_skill_owned_by_a_bot(shared_world: World) -> None:
    w = shared_world
    assert w.probe("bob", CREATE, {"MADE": "bob-made"}).get("success")
    result = w.probe("alice", """
import asyncio
from hermes_cli.web_models import SkillContentUpdate
from hermes_cli.web_routers.skills import update_skill_content
content = "---\\nname: bob-made\\ndescription: Use when probing bob-made.\\n---\\n\\nHUMAN_EDIT\\n"
emit(asyncio.run(update_skill_content(SkillContentUpdate(name="bob-made", content=content), profile=None)))
""")
    assert result.get("success"), result
    assert "HUMAN_EDIT" in skill_text(w, "bob-made")


def test_renaming_a_bot_keeps_its_skills_editable_by_it_and_only_it(shared_world: World) -> None:
    w = shared_world
    assert w.probe("alice", CREATE, {"MADE": "alice-made"}).get("success")
    assert origins_of(w)["alice-made"] == {"origin": "bot", "owner": "alice"}

    w.hermes_ok("default", "profile", "rename", "alice", "alicia")

    assert origins_of(w)["alice-made"] == {"origin": "bot", "owner": "alicia"}
    own = w.probe("alicia", OWN_EDIT, {"TARGET": "alice-made"})
    assert own["patched"].get("success"), own
    other = w.probe("bob", OWN_EDIT, {"TARGET": "alice-made"})
    assert SHARED_REFUSAL in json.dumps(other["patched"])
    assert "MARK_ALICE_MADE" in w.visible_markers("alicia")


def test_deleting_a_bot_orphans_its_skills_off_for_everyone_who_did_not_enable_them_and_editable_by_no_bot(
    shared_world: World,
) -> None:
    w = shared_world
    assert w.probe("alice", CREATE, {"MADE": "alice-made"}).get("success")
    assert w.probe("alice", CREATE, {"MADE": "alice-other"}).get("success")
    w.enable_skill("bob", "alice-made")

    proc = w.hermes("default", "profile", "delete", "alice", "--yes")
    assert proc.returncode == 0, proc.stderr[-1500:]

    origins = origins_of(w)
    assert origins["alice-made"] == {"origin": "bot", "owner": None}
    assert origins["alice-other"] == {"origin": "bot", "owner": None}
    assert "unowned" in proc.stdout

    assert not usable(w.surfaces("bob", ["alice-made"])["alice-made"], "MARK_ALICE_MADE")
    assert "MARK_ALICE_OTHER" not in w.visible_markers("bob")
    assert "MARK_ALICE_OTHER" not in w.visible_markers("default")
    for bot in ("bob", "default"):
        row = w.probe(bot, OWN_EDIT, {"TARGET": "alice-made"})["patched"]
        assert row.get("success") is False and SHARED_REFUSAL in json.dumps(row), f"{bot} edited an orphan: {row}"


@pytest.fixture
def world(tmp_path: Path) -> World:
    w = World(tmp_path)
    write_skill(w.default / "skills", "common")
    w.add_bot(
        "alice",
        skills={"common": {}, "only-alice": {}},
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_ALICE)},
    )
    w.add_bot(
        "bob",
        skills={"common": {}, "only-bob": {}},
        mcp_servers={"shared-fs": dict(FS), "github": dict(GH_BOB)},
    )
    return w


def manifest_of(backup: Path) -> dict:
    return json.loads((backup / "manifest.json").read_text(encoding="utf-8"))


def test_a_bot_whose_switch_over_fails_is_skipped_reported_and_the_migration_still_completes(world: World) -> None:
    result = world.probe("default", """
import os
from pathlib import Path
import hermes_cli.shared_catalog_migrate as m
from hermes_cli.config_backend import ConfigBackendUnavailable

real = m._write_bot_config
broken = {Path(os.environ["ALICE_HOME"]): ConfigBackendUnavailable("no config file backend"),
          Path(os.environ["BOB_HOME"]): RuntimeError("disk full")}

def flaky(home, plan):
    if home in broken:
        raise broken[home]
    return real(home, plan)

m._write_bot_config = flaky
lines = []
emit({"rc": m.migrate(say=lines.append), "lines": lines})
""", {"ALICE_HOME": str(world.home_of("alice")), "BOB_HOME": str(world.home_of("bob"))})
    assert result["rc"] == 0
    manifest = manifest_of(backups(world)[-1])
    assert manifest["status"] == "done"
    assert set(manifest["failed_bots"]) == {"alice", "bob"}
    reported = "\n".join(result["lines"])
    assert "alice: could not be switched" in reported and "bob: could not be switched" in reported
    assert "no config file backend" in manifest["failed_bots"]["alice"] and "disk full" in manifest["failed_bots"]["bob"]
    assert (world.catalog / ".migrated").exists()

    again = world.hermes_ok("default", "catalog", "migrate")
    assert "already migrated" in again.stdout and "Finishing" not in again.stdout
    assert manifest_of(backups(world)[-1])["status"] == "done"

    world.hermes_ok("default", "catalog", "migrate", "--retry-failed")
    manifest = manifest_of(backups(world)[-1])
    assert manifest["status"] == "done" and manifest["failed_bots"] == {}
    assert "only-alice" in world.config("alice")["skills"]["enabled"]
    assert "only-bob" in world.config("bob")["skills"]["enabled"]
    assert "MARK_ONLY_ALICE" in world.visible_markers("alice")


def test_an_update_driven_migration_survives_a_config_backend_that_cannot_serve_a_bot(world: World) -> None:
    result = world.probe("default", """
from hermes_cli.config_backend import ConfigBackendUnavailable
import hermes_cli.shared_catalog_migrate as m
import hermes_cli.update_cmd_maint as maint

def refuse(*args, **kwargs):
    raise ConfigBackendUnavailable("no config file backend")

m._write_bot_config = refuse
maint._sync_profiles_after_update()
emit({"survived": True})
""")
    assert result == {"survived": True}
    assert manifest_of(backups(world)[-1])["status"] == "done"


def test_importing_a_flat_skill_that_differs_from_the_catalog_copy_is_renamed_not_treated_as_identical(
    shared_world: World, tmp_path: Path,
) -> None:
    w = shared_world
    catalog_skills = w.catalog / "skills"
    (catalog_skills / "notes.md").write_text("---\nname: notes\ndescription: catalog copy\n---\nCATALOG_NOTES\n", encoding="utf-8")
    incoming = tmp_path / "incoming"
    (incoming / "skills").mkdir(parents=True)
    (incoming / "skills" / "notes.md").write_text("---\nname: notes\ndescription: other copy\n---\nOTHER_NOTES\n", encoding="utf-8")
    (incoming / "skills" / "same.md").write_text("---\nname: same\ndescription: same\n---\nSAME\n", encoding="utf-8")
    (catalog_skills / "same.md").write_text("---\nname: same\ndescription: same\n---\nSAME\n", encoding="utf-8")
    (incoming / "config.yaml").write_text("{}\n", encoding="utf-8")

    wanted = w.probe("alice", """
import os
from pathlib import Path
from hermes_cli.shared_catalog_portable import adopt_profile_skills
emit(adopt_profile_skills(Path(os.environ["INCOMING"]), "alice"))
""", {"INCOMING": str(incoming)})

    assert "alice-notes" in wanted and "notes" not in wanted, wanted
    assert "same" in wanted
    assert "CATALOG_NOTES" in (catalog_skills / "notes.md").read_text(encoding="utf-8"), "the catalog copy was overwritten"
    assert "OTHER_NOTES" in (catalog_skills / "alice-notes.md").read_text(encoding="utf-8")
    assert not (catalog_skills / "alice-same.md").exists()


def test_skills_kept_in_the_profile_builder_that_are_off_by_default_are_turned_on_for_that_bot(shared_world: World) -> None:
    w = shared_world
    w.catalog_skill("dropped-in")
    w.catalog_skill("other-dropped")
    w.catalog_skill("shipped", bundled=True)
    result = w.probe("alice", """
import os
from pathlib import Path
from hermes_cli.web_routers.profiles import _disable_unselected_skills
newly = _disable_unselected_skills(Path(os.environ["ALICE_HOME"]), ["dropped-in"])
emit({"newly": newly})
""", {"ALICE_HOME": str(w.home_of("alice"))})
    skills_cfg = w.config("alice")["skills"]
    assert skills_cfg["enabled"] == ["dropped-in"], skills_cfg
    assert "shipped" in skills_cfg["disabled"], "an unkept bundled skill must be off"
    assert result["newly"] >= 1
    assert w.visible_markers("alice") == {"MARK_DROPPED_IN"}
    assert w.visible_markers("bob") == {"MARK_SHIPPED"}


EDITOR = """
import asyncio, json, os
from fastapi import HTTPException
from hermes_cli.config import read_user_config_raw
from hermes_cli.mcp_config import _get_mcp_servers
from hermes_cli.shared_catalog import read_mcp_definitions
from hermes_cli.web_models import MCPServersReplace
from hermes_cli.web_routers.mcp import replace_mcp_servers

def view():
    return json.loads(json.dumps(_get_mcp_servers(read_user_config_raw())))

def put(servers, **flags):
    try:
        asyncio.run(replace_mcp_servers(MCPServersReplace(servers=servers, **flags), profile=None))
        return {"status": 200}
    except HTTPException as exc:
        return {"status": exc.status_code, "detail": exc.detail}

def state():
    return {"bot": read_user_config_raw().get("mcp_servers"), "shared": read_mcp_definitions()}

"""


def editor_world(tmp_path: Path) -> World:
    w = World(tmp_path)
    w.add_bot("alice", mcp_servers={"shared-fs": {"enabled": True}})
    w.add_bot("bob")
    w.save_catalog_mcp({
        "shared-fs": dict(FS),
        "notes": {"command": "npx", "args": ["-y", "notes-server"]},
        "wiki": {"url": "http://127.0.0.1:9/wiki"},
    })
    return w


def test_the_mcp_editor_saves_only_this_bots_opt_ins_and_never_marks_it_a_user_of_every_shared_server(tmp_path: Path) -> None:
    w = editor_world(tmp_path)
    out = w.probe("alice", EDITOR + """
shown = view()
saved = put(shown)
emit({"shown": sorted(shown), "saved": saved, "state": state()})
""")
    assert out["shown"] == ["notes", "shared-fs", "wiki"]
    assert out["saved"] == {"status": 200}
    assert out["state"]["bot"] == {"shared-fs": {"enabled": True}}, out["state"]["bot"]
    assert out["state"]["shared"]["shared-fs"] == FS and set(out["state"]["shared"]) == {"shared-fs", "notes", "wiki"}
    assert "alice" not in w.probe("bob", """
from hermes_cli.shared_catalog import _other_profiles_using
emit(_other_profiles_using("notes"))
""")


def test_the_mcp_editor_asks_for_confirmation_before_changing_a_shared_definition(tmp_path: Path) -> None:
    w = editor_world(tmp_path)
    out = w.probe("alice", EDITOR + """
shown = view()
shown["shared-fs"]["args"] = ["-y", "fs-server", "--changed"]
refused = put(shown)
after_refusal = state()
confirmed = put(shown, replace_shared=True)
emit({"refused": refused, "after_refusal": after_refusal, "confirmed": confirmed, "state": state()})
""")
    assert out["refused"]["status"] == 409 and "shared-fs" in out["refused"]["detail"], out["refused"]
    assert "notes" not in out["refused"]["detail"]
    assert out["after_refusal"]["shared"]["shared-fs"] == FS, "the shared definition changed without confirmation"
    assert out["after_refusal"]["bot"] == {"shared-fs": {"enabled": True}}
    assert out["confirmed"] == {"status": 200}
    assert out["state"]["shared"]["shared-fs"]["args"] == ["-y", "fs-server", "--changed"]
    assert out["state"]["bot"] == {"shared-fs": {"enabled": True}}


def test_deleting_a_shared_server_in_the_mcp_editor_drops_only_this_bots_opt_in_unless_told_to_remove_it_everywhere(
    tmp_path: Path,
) -> None:
    w = editor_world(tmp_path)
    out = w.probe("alice", EDITOR + """
shown = view()
without = {k: v for k, v in shown.items() if k != "shared-fs"}
first = put(without)
after_first = state()
w2 = put({"shared-fs": {"enabled": True, **json.loads(json.dumps(shown["shared-fs"]))}})
second = put({k: v for k, v in view().items() if k != "shared-fs"}, everywhere=True)
emit({"first": first, "after_first": after_first, "w2": w2, "second": second, "final": state()})
""")
    assert out["first"] == {"status": 200}
    assert out["after_first"]["bot"] is None
    assert "shared-fs" in out["after_first"]["shared"], "a bot removing its opt-in deleted the shared definition"
    assert out["w2"] == {"status": 200}
    assert out["second"] == {"status": 200}
    assert "shared-fs" not in out["final"]["shared"], "the confirmed delete did not remove it everywhere"
    assert {"notes", "wiki"} <= set(out["final"]["shared"])
    assert out["final"]["bot"] is None


def test_the_delete_endpoint_removes_one_bots_opt_in_and_only_deletes_the_definition_when_asked(tmp_path: Path) -> None:
    w = editor_world(tmp_path)
    out = w.probe("alice", """
import asyncio, json
from hermes_cli.config import read_user_config_raw
from hermes_cli.shared_catalog import read_mcp_definitions
from hermes_cli.web_routers.mcp import remove_mcp_server

asyncio.run(remove_mcp_server("shared-fs", profile=None))
local = {"bot": read_user_config_raw().get("mcp_servers"), "shared": sorted(read_mcp_definitions())}
asyncio.run(remove_mcp_server("shared-fs", profile=None, everywhere=True))
emit({"local": local, "everywhere": sorted(read_mcp_definitions())})
""")
    assert out["local"] == {"bot": None, "shared": ["notes", "shared-fs", "wiki"]}
    assert out["everywhere"] == ["notes", "wiki"]


def test_rolling_back_gives_a_bot_created_after_the_migration_its_bundled_skills(world: World) -> None:
    migrate(world)
    world.hermes_ok("default", "profile", "create", "fresh", "--no-alias", timeout=300)
    assert not list((world.home_of("fresh") / "skills").rglob("SKILL.md")), "post-migration bot should hold no local copies yet"

    out = world.hermes_ok("default", "catalog", "migrate", "--rollback", timeout=300).stdout

    fresh_skills = world.home_of("fresh") / "skills"
    assert (fresh_skills / ".bundled_manifest").exists(), out
    assert list(fresh_skills.rglob("SKILL.md")), f"a bot created after the migration lost every bundled skill\n{out}"
    assert "fresh: created after the migration; seeded the bundled skills" in out


def test_a_remote_sandbox_receives_only_the_skills_enabled_for_that_bot(shared_world: World) -> None:
    w = shared_world
    w.catalog_skill("dropped-in", enabled_for=["alice"])
    w.catalog_skill("other-dropped")
    w.catalog_skill("shipped", bundled=True)
    w.catalog_skill("off-bundled", bundled=True)
    w.disable_skill("alice", "off-bundled")
    probe = """
from tools.credential_files import get_skills_directory_mount, iter_skills_files
emit({
    "dirs": sorted(m["container_path"] for m in get_skills_directory_mount()),
    "files": sorted(m["container_path"] for m in iter_skills_files()),
})
"""
    alice = w.probe("alice", probe)
    assert alice["dirs"] == ["/root/.hermes/skills/dropped-in", "/root/.hermes/skills/shipped"], alice
    assert "/root/.hermes/skills/dropped-in/SKILL.md" in alice["files"]
    assert "/root/.hermes/skills/shipped/references/notes.md" in alice["files"]
    assert not [f for f in alice["files"] if "other-dropped" in f or "off-bundled" in f], alice["files"]

    bob = w.probe("bob", probe)
    assert bob["dirs"] == ["/root/.hermes/skills/off-bundled", "/root/.hermes/skills/shipped"], bob
    assert not [f for f in bob["files"] if "dropped" in f]

    w.enable_skill("alice", "other-dropped")
    assert "/root/.hermes/skills/other-dropped" in w.probe("alice", probe)["dirs"]
