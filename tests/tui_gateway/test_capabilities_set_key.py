"""capabilities.set_key: set, replace and remove a capability key per bot, the rows flip, and the value
appears nowhere but that bot's own .env."""

from __future__ import annotations

import json
import logging
import uuid

import pytest

from hermes_cli.config import load_env
from hermes_cli.profiles import get_profile_dir
from tests.tui_gateway import test_capabilities_status_rpc as base
from tui_gateway import server
from tui_gateway.contracts import METHODS


bots, browser_host, disabled_skills, web_provider = base.bots, base.browser_host, base.disabled_skills, base.web_provider
_status, _write_browser_config = base._status, base._write_browser_config


def _canary() -> str:
    return f"CANARY-{uuid.uuid4().hex}"


def _call(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _set(profile: str, key: str, value: str | None) -> dict:
    params = {"profile": profile, "key_name": key, "value": value}
    response = _call("capabilities.set_key", params)
    assert "error" not in response, response.get("error")
    METHODS["capabilities.set_key"].params.model_validate(params)
    return METHODS["capabilities.set_key"].result.model_validate(response["result"]).model_dump(mode="json")


def _env(profile: str) -> dict[str, str]:
    path = get_profile_dir(profile) / ".env"
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line) if path.exists() else {}


def test_set_replace_and_remove_flip_the_maps_row(bots, web_provider, disabled_skills):
    assert _status()["maps"]["key_name"] == "GOOGLE_MAPS_API_KEY"
    first = _canary()
    result = _set("scout", "GOOGLE_MAPS_API_KEY", first)
    assert result["is_set"] is True and result["key_name"] == "GOOGLE_MAPS_API_KEY"
    row = next(r for r in result["capabilities"] if r["id"] == "maps")
    assert row["reason"] is None and row["key_name"] is None
    assert _env("scout")["GOOGLE_MAPS_API_KEY"] == first
    second = _canary()
    _set("scout", "GOOGLE_MAPS_API_KEY", second)
    assert _env("scout")["GOOGLE_MAPS_API_KEY"] == second
    result = _set("scout", "GOOGLE_MAPS_API_KEY", None)
    assert result["is_set"] is False
    assert "GOOGLE_MAPS_API_KEY" not in _env("scout")
    assert _status()["maps"]["key_name"] == "GOOGLE_MAPS_API_KEY"


def test_a_browser_provider_key_turns_the_off_row_on(browser_host):
    _write_browser_config("scout", cloud_provider="browser-use")
    row = _status()["browser"]
    assert row["state"] == "off" and "BROWSER_USE_API_KEY" in row["key_choices"]
    result = _set("scout", "BROWSER_USE_API_KEY", _canary())
    assert next(r for r in result["capabilities"] if r["id"] == "browser")["state"] == "on"
    _set("scout", "BROWSER_USE_API_KEY", None)
    assert _status()["browser"]["state"] == "off"


def test_a_search_key_turns_web_search_on(bots, disabled_skills, monkeypatch):
    for key in ("TAVILY_API_KEY", "PERPLEXITY_API_KEY", "EXA_API_KEY", "FIRECRAWL_API_KEY", "BRAVE_SEARCH_API_KEY",
                "SEARXNG_URL"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr("tools.web_tools.check_web_api_key",
                        lambda: bool(load_env().get("TAVILY_API_KEY")))
    row = _status()["web"]
    assert row["state"] == "off" and "TAVILY_API_KEY" in row["key_choices"]
    result = _set("scout", "TAVILY_API_KEY", _canary())
    assert next(r for r in result["capabilities"] if r["id"] == "web")["state"] == "on"


def test_a_key_set_for_one_bot_never_reaches_another(bots, web_provider, disabled_skills):
    _set("scout", "YOUTUBE_API_KEY", _canary())
    assert _status("scout")["youtube"]["key_name"] is None
    assert _status("pilot")["youtube"]["key_name"] == "YOUTUBE_API_KEY"
    assert "YOUTUBE_API_KEY" not in _env("pilot")


@pytest.mark.parametrize("key", ["OPENAI_API_KEY", "SLACK_BOT_TOKEN", "HERMES_HOME", "youtube_api_key", "X", ""])
def test_a_key_the_capabilities_do_not_name_is_refused_and_nothing_is_written(bots, key):
    response = _call("capabilities.set_key", {"profile": "scout", "key_name": key, "value": _canary()})
    assert "error" in response
    assert _env("scout") == {}


@pytest.mark.parametrize("value", ["", "   ", "two\nlines", "naïve", "x" * 4097])
def test_a_value_that_cannot_be_a_key_is_refused_without_echoing_it(bots, value):
    response = _call("capabilities.set_key", {"profile": "scout", "key_name": "YOUTUBE_API_KEY", "value": value})
    assert "error" in response
    assert value.strip() == "" or value not in json.dumps(response)
    assert _env("scout") == {}


def test_an_unknown_bot_is_refused_and_nothing_is_stored(bots):
    response = _call("capabilities.set_key", {"profile": "ghost", "key_name": "YOUTUBE_API_KEY", "value": _canary()})
    assert "error" in response
    assert not (get_profile_dir("ghost") / ".env").exists()
    assert _env("scout") == {} and _env("pilot") == {}


def test_a_failed_write_keeps_the_old_value(bots, web_provider, disabled_skills, monkeypatch, caplog):
    old, new = _canary(), _canary()
    _set("scout", "YOUTUBE_API_KEY", old)

    def refuse(*args, **kwargs):
        raise OSError(f"disk refused {new}")

    caplog.set_level(logging.DEBUG)
    with monkeypatch.context() as patch:
        patch.setattr("hermes_cli.config.atomic_replace", refuse)
        response = _call("capabilities.set_key", {"profile": "scout", "key_name": "YOUTUBE_API_KEY", "value": new})
    assert response["error"]["code"] == 5103
    assert new not in json.dumps(response) + caplog.text
    assert _env("scout")["YOUTUBE_API_KEY"] == old
    assert _status()["youtube"]["key_name"] is None


def test_the_value_reaches_only_the_bots_env_file(bots, web_provider, disabled_skills, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    first, second = _canary(), _canary()
    answers = [_set("scout", "YOUTUBE_API_KEY", first), _set("scout", "YOUTUBE_API_KEY", second),
               _call("capabilities.status", {"profile": "scout"}), _set("scout", "YOUTUBE_API_KEY", None)]
    out = capsys.readouterr()
    outside = json.dumps(answers) + caplog.text + out.out + out.err
    assert first not in outside and second not in outside
