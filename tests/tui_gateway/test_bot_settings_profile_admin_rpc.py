from __future__ import annotations

from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir, list_profile_names
from tui_gateway import server


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    return home


def _call(method: str, params: dict) -> dict:
    return server._methods[method](1, params)


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _call(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def test_rename_requires_both_names_and_an_existing_bot(two_bots):
    assert _call("profiles.rename", {"new_name": "x"})["error"]["code"] == 4063
    assert _call("profiles.rename", {"name": "ghost", "new_name": "x"})["error"]["code"] == 4064
    assert _call("profiles.rename", {"name": "scout"})["error"]["code"] == 4101
    assert _call("profiles.rename", {"name": "scout", "new_name": "   "})["error"]["code"] == 4101


def test_rename_refuses_a_taken_or_reserved_name_and_leaves_the_bot_alone(two_bots):
    assert _call("profiles.rename", {"name": "scout", "new_name": "pilot"})["error"]["code"] == 4102
    assert _call("profiles.rename", {"name": "scout", "new_name": "default"})["error"]["code"] == 4102
    assert _call("profiles.rename", {"name": "scout", "new_name": "bad name!"})["error"]["code"] == 4102
    assert sorted(list_profile_names()) == ["default", "pilot", "scout"]


def test_rename_moves_the_bot_and_answers_its_new_canonical_id(two_bots):
    old_dir = get_profile_dir("scout")
    result = _ok("profiles.rename", {"name": "scout", "new_name": "Ranger"})
    assert result["name"] == "ranger" and result.get("display_name") is None
    assert not old_dir.exists() and get_profile_dir("ranger").is_dir()
    assert "scout" not in list_profile_names() and "pilot" in list_profile_names()


def test_renaming_the_primary_bot_changes_only_its_display_name(two_bots):
    result = _ok("profiles.rename", {"name": "default", "new_name": "Nova"})
    assert result["name"] == "default" and result["display_name"] == "Nova"
    listed = {row["name"]: row for row in _ok("profiles.list", {"include_sessions": False})["profiles"]}
    assert listed["default"]["display_name"] == "Nova" and listed["default"]["is_default"] is True


def test_the_bot_serving_the_connection_cannot_be_renamed_or_deleted(two_bots, monkeypatch):
    monkeypatch.setattr(server, "_hermes_home", get_profile_dir("scout"))
    assert _call("profiles.rename", {"name": "scout", "new_name": "ranger"})["error"]["code"] == 4102
    assert _call("profiles.delete", {"name": "scout"})["error"]["code"] == 4102
    assert get_profile_dir("scout").is_dir()


def test_delete_refuses_the_primary_bot_and_removes_nothing(two_bots):
    response = _call("profiles.delete", {"name": "default"})
    assert response["error"]["code"] == 4102
    assert two_bots.is_dir() and sorted(list_profile_names()) == ["default", "pilot", "scout"]


def test_delete_needs_an_existing_bot(two_bots):
    assert _call("profiles.delete", {})["error"]["code"] == 4063
    assert _call("profiles.delete", {"name": "ghost"})["error"]["code"] == 4064


def test_delete_removes_only_the_named_bot(two_bots):
    doomed = get_profile_dir("scout")
    result = _ok("profiles.delete", {"name": "scout"})
    assert result["name"] == "scout" and not doomed.exists()
    assert sorted(list_profile_names()) == ["default", "pilot"] and get_profile_dir("pilot").is_dir()


def test_a_bots_id_is_its_name_and_a_rename_keeps_the_old_id_resolvable(two_bots):
    roster = _ok("profiles.list", {"include_sessions": False})
    assert roster["install_id"] and {row["name"] for row in roster["profiles"]} == {"default", "scout", "pilot"}
    _ok("profiles.rename", {"name": "scout", "new_name": "ranger"})
    renamed = {row["name"]: row for row in _ok("profiles.list", {"include_sessions": False})["profiles"]}
    assert "scout" not in renamed and renamed["ranger"]["previous_names"] == ["scout"]
