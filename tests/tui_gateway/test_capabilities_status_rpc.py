"""capabilities.status: each row flips with the bot's own config, keys appear by name only, and one bot's
state never shows up in another's answer."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from gateway import device_connectors
from gateway.device_actions import Connector
from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import capabilities_status, server
from tui_gateway.contracts import METHODS

YOUTUBE_SECRET = "yt-SECRETVALUE-111111"
MAPS_SECRET = "gm-SECRETVALUE-222222"


@pytest.fixture
def bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in ("YOUTUBE_API_KEY", "GOOGLE_MAPS_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    return home


@pytest.fixture
def web_provider(monkeypatch) -> dict:
    state = {"available": True}
    monkeypatch.setattr("tools.web_tools.check_web_api_key", lambda: state["available"])
    return state


@pytest.fixture
def disabled_skills(monkeypatch) -> set:
    names: set = set()
    monkeypatch.setattr(capabilities_status, "_skills_disabled", lambda: names)
    return names


def _status(profile: str = "scout") -> dict[str, dict]:
    response = server.handle_request({"id": "1", "method": "capabilities.status", "params": {"profile": profile}})
    assert "error" not in response, response.get("error")
    result = METHODS["capabilities.status"].result.model_validate(response["result"])
    assert result.profile == profile
    return {row["id"]: row for row in response["result"]["capabilities"]}


def _write_env(profile: str, **values: str) -> None:
    path = get_profile_dir(profile) / ".env"
    path.write_text("".join(f"{key}={value}\n" for key, value in values.items()))


def test_lists_the_five_capabilities_in_a_stable_order(bots, web_provider, disabled_skills):
    assert list(_status()) == ["web", "deep_search", "youtube", "maps", "browser"]


def test_web_search_follows_provider_availability(bots, web_provider, disabled_skills):
    assert _status()["web"]["state"] == "on" and _status()["web"]["reason"] is None
    web_provider["available"] = False
    row = _status()["web"]
    assert row["state"] == "off" and row["setting"] == "web.search_backend"
    assert "TAVILY_API_KEY" in row["reason"] and "terminal" in row["reason"]


def test_deep_search_needs_web_and_its_skill(bots, web_provider, disabled_skills):
    assert _status()["deep_search"]["state"] == "on"
    web_provider["available"] = False
    row = _status()["deep_search"]
    assert row["state"] == "off" and "web search" in row["reason"]
    web_provider["available"] = True
    disabled_skills.add("deep-search")
    row = _status()["deep_search"]
    assert row["state"] == "off" and row["setting"] == "skills.disabled"


def test_youtube_key_flips_the_note_and_keeps_transcripts_on(bots, web_provider, disabled_skills):
    row = _status()["youtube"]
    assert row["state"] == "on" and row["key_name"] == "YOUTUBE_API_KEY"
    assert "Transcripts only" in row["reason"]
    _write_env("scout", YOUTUBE_API_KEY=YOUTUBE_SECRET)
    row = _status()["youtube"]
    assert row["state"] == "on" and row["reason"] is None and row["key_name"] is None
    disabled_skills.add("youtube-content")
    assert _status()["youtube"]["state"] == "off"


def test_maps_key_flips_openstreetmap_only(bots, web_provider, disabled_skills):
    row = _status()["maps"]
    assert row["state"] == "on" and row["key_name"] == "GOOGLE_MAPS_API_KEY"
    assert row["reason"].startswith("OpenStreetMap only")
    _write_env("scout", GOOGLE_MAPS_API_KEY=MAPS_SECRET)
    row = _status()["maps"]
    assert row["state"] == "on" and row["reason"] is None and row["key_name"] is None
    disabled_skills.add("maps")
    assert _status()["maps"]["state"] == "off"


def test_no_key_value_reaches_the_result(bots, web_provider, disabled_skills):
    _write_env("scout", YOUTUBE_API_KEY=YOUTUBE_SECRET, GOOGLE_MAPS_API_KEY=MAPS_SECRET)
    response = server.handle_request({"id": "1", "method": "capabilities.status", "params": {"profile": "scout"}})
    blob = json.dumps(response)
    assert YOUTUBE_SECRET not in blob and MAPS_SECRET not in blob


def test_one_bots_keys_never_show_in_another_bots_answer(bots, web_provider, disabled_skills):
    _write_env("scout", YOUTUBE_API_KEY=YOUTUBE_SECRET)
    assert _status("scout")["youtube"]["key_name"] is None
    assert _status("pilot")["youtube"]["key_name"] == "YOUTUBE_API_KEY"


def test_an_unknown_bot_is_an_error_not_the_default_bots_state(bots, web_provider, disabled_skills):
    response = server.handle_request({"id": "1", "method": "capabilities.status", "params": {"profile": "ghost"}})
    assert "error" in response and "result" not in response


def test_browser_is_not_yet_available_until_a_connector_exists(bots, web_provider, disabled_skills):
    assert getattr(Connector, "BROWSER", None) is None
    row = _status()["browser"]
    assert row["state"] == "not_yet_available" and row["reason"]


@pytest.fixture
def browser_connector(monkeypatch):
    monkeypatch.setattr(capabilities_status, "_browser_connector", lambda: Connector.SHELL)
    return Connector.SHELL


def test_browser_row_flips_with_devices_and_connector_state(bots, web_provider, disabled_skills, browser_connector):
    home = Path(get_profile_dir("scout"))
    row = _status()["browser"]
    assert row["state"] == "unavailable" and row["reason"] == "No device online."

    device_connectors.register_device(home, "mac-1", "Work Mac", kind="mac")
    row = _status()["browser"]
    assert row["state"] == "off" and row["reason"].startswith("Browser connector off on ")

    device_connectors.update(home, "mac-1", browser_connector, state=device_connectors.ConnectorState.ALLOWED)
    assert _status()["browser"]["state"] == "on"


def test_browser_devices_of_another_bot_do_not_count(bots, web_provider, disabled_skills, browser_connector):
    other = Path(get_profile_dir("pilot"))
    device_connectors.register_device(other, "mac-9", "Other Mac", kind="mac")
    device_connectors.update(other, "mac-9", browser_connector, state=device_connectors.ConnectorState.ALLOWED)
    assert _status("scout")["browser"]["state"] == "unavailable"
    assert _status("pilot")["browser"]["state"] == "on"
