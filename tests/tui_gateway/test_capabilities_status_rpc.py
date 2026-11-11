"""capabilities.status: each row flips with the bot's own config, keys appear by name only, and one bot's
state never shows up in another's answer."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import hermes_yaml as yaml
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


BROWSER_SECRET = "bu-SECRETVALUE-333333"
BROWSER_ENV_KEYS = ("BROWSER_USE_API_KEY", "BROWSERBASE_API_KEY", "BROWSERBASE_PROJECT_ID", "BROWSER_CDP_URL")


@pytest.fixture
def browser_host(bots, web_provider, disabled_skills, monkeypatch) -> dict:
    from tools import browser_session_cloud

    state = {"engine": True}
    for key in BROWSER_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr("tools.browser_use_cli.browser_exec_available", lambda: state["engine"])
    browser_session_cloud.reset_caches()
    yield state
    browser_session_cloud.reset_caches()


def _write_browser_config(profile: str, **browser) -> None:
    (get_profile_dir(profile) / "config.yaml").write_text(yaml.safe_dump({"browser": browser}))


def test_browser_defaults_to_the_bots_own_local_browser(browser_host):
    row = _status()["browser"]
    assert row["state"] == "on" and row["reason"] is None


def test_browser_selected_provider_without_credentials_is_off_and_names_the_keys(browser_host):
    _write_browser_config("scout", cloud_provider="browserbase")
    row = _status()["browser"]
    assert row["state"] == "off" and row["setting"] == "browser.cloud_provider"
    assert "browserbase" in row["reason"] and "BROWSERBASE_API_KEY" in row["reason"]
    assert "not yet" not in row["reason"].lower() and "Mac" not in row["reason"]


def test_browser_selected_provider_turns_on_with_its_keys(browser_host):
    _write_browser_config("scout", cloud_provider="browser-use")
    assert _status()["browser"]["state"] == "off"
    _write_env("scout", BROWSER_USE_API_KEY=BROWSER_SECRET)
    row = _status()["browser"]
    assert row["state"] == "on" and row["reason"] is None


def test_browser_selected_provider_that_is_not_installed_is_off(browser_host):
    _write_browser_config("scout", cloud_provider="no-such-provider")
    row = _status()["browser"]
    assert row["state"] == "off" and "not installed" in row["reason"]


def test_browser_explicit_local_engine_is_on(browser_host):
    _write_browser_config("scout", cloud_provider="local")
    assert _status()["browser"]["state"] == "on"


def test_browser_cdp_endpoint_is_on(browser_host):
    _write_browser_config("scout", cdp_url="http://127.0.0.1:9222")
    assert _status()["browser"]["state"] == "on"


def test_browser_is_unavailable_when_the_host_cannot_run_one(browser_host):
    browser_host["engine"] = False
    row = _status()["browser"]
    assert row["state"] == "unavailable" and "cannot run a browser" in row["reason"]


def test_browser_key_value_never_reaches_the_result(browser_host):
    _write_browser_config("scout", cloud_provider="browser-use")
    _write_env("scout", BROWSER_USE_API_KEY=BROWSER_SECRET)
    response = server.handle_request({"id": "1", "method": "capabilities.status", "params": {"profile": "scout"}})
    assert BROWSER_SECRET not in json.dumps(response)


def test_one_bots_browser_key_does_not_turn_on_another_bots_browser(browser_host):
    for profile in ("scout", "pilot"):
        _write_browser_config(profile, cloud_provider="browser-use")
    _write_env("scout", BROWSER_USE_API_KEY=BROWSER_SECRET)
    assert _status("scout")["browser"]["state"] == "on"
    assert _status("pilot")["browser"]["state"] == "off"
