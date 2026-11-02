from __future__ import annotations

from pathlib import Path

import pytest

from tests.e2e.core.bots._world import World, write_skill

FINGERPRINT = "from tools.bot_mode_probe import capability_fingerprint\nemit(capability_fingerprint())\n"

REREAD = """
from tools import skills_tool
from tools.bot_mode_probe import capability_fingerprint

reads = []
original = skills_tool._read_skill_text
skills_tool._read_skill_text = lambda path, *a, **k: (reads.append(str(path)), original(path, *a, **k))[1]
first = capability_fingerprint()
cold = len(reads)
second = capability_fingerprint()
emit({"same": first == second, "cold_reads": cold, "warm_reads": len(reads) - cold})
"""


@pytest.fixture
def world(tmp_path: Path) -> World:
    w = World(tmp_path)
    w.add_bot("alice")
    w.add_bot("bob")
    w.catalog_skill("alpha", enabled_for=["alice"])
    w.catalog_skill("beta", enabled_for=["bob"])
    return w


def fingerprint(w: World, bot: str) -> str:
    return w.probe(bot, FINGERPRINT)


def test_another_bots_skill_writes_never_move_this_bots_epoch(world: World) -> None:
    before = fingerprint(world, "alice")
    world.catalog_skill("bob-new", enabled_for=["bob"])
    assert fingerprint(world, "alice") == before
    write_skill(world.catalog / "skills", "beta", marker="PATCHED_BY_BOB")
    assert fingerprint(world, "alice") == before


def test_an_enabled_skills_body_edit_does_not_move_the_epoch_but_its_description_does(world: World) -> None:
    before = fingerprint(world, "alice")
    write_skill(world.catalog / "skills", "alpha", marker="NEW_BODY")
    assert fingerprint(world, "alice") == before
    skill = world.catalog / "skills" / "alpha" / "SKILL.md"
    skill.write_text(skill.read_text(encoding="utf-8").replace("probing alpha", "probing alpha differently"),
                     encoding="utf-8")
    assert fingerprint(world, "alice") != before


def test_this_bots_enabled_set_moves_the_epoch(world: World) -> None:
    world.catalog_skill("bob-new", enabled_for=["bob"])
    before = fingerprint(world, "alice")
    world.enable_skill("alice", "bob-new")
    enabled = fingerprint(world, "alice")
    assert enabled != before
    world.disable_skill("alice", "alpha")
    assert fingerprint(world, "alice") not in {before, enabled}


def test_a_warm_fingerprint_rereads_no_skill_files(world: World) -> None:
    out = world.probe("alice", REREAD)
    assert out["same"] and out["warm_reads"] == 0, out
