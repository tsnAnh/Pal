from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from hermes_cli.config import load_env
from hermes_cli.profiles import create_profile, get_profile_dir, write_profile_meta
from tui_gateway import server

BOT_TOKEN = "xoxb-1111111111-2222222222-ScoutBotTokenSecretValue"
APP_TOKEN = "xapp-1-A0ABCDEFGH-3333333333-ScoutAppTokenSecretValue"


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_ALLOWED_USERS"):
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    write_profile_meta(get_profile_dir("scout"), display_name="Scout Prime", description="Watches the build")
    return home


@pytest.fixture
def gateway_reload(monkeypatch):
    from hermes_cli.web_routers import messaging

    calls = {"hot": [], "restart": []}
    hot_served = {"value": False}

    def hot(profile):
        calls["hot"].append(profile)
        return hot_served["value"]

    def restart(profile, *, what, label):
        calls["restart"].append(profile)
        return {"restart_started": True}

    monkeypatch.setattr(messaging, "_notify_multiplexer_hot_serve", hot)
    monkeypatch.setattr(messaging, "_restart_gateway_after", restart)
    calls["hot_served"] = hot_served
    return calls


def _rpc(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _env_of(profile: str) -> dict[str, str]:
    path = get_profile_dir(profile) / ".env"
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line and not line.startswith("#"))


def _connect(profile: str = "scout", **overrides) -> dict:
    return _rpc("messaging.slack.connect", {"profile": profile, "bot_token": BOT_TOKEN, "app_token": APP_TOKEN, **overrides})


def test_connect_refuses_missing_or_misplaced_tokens_and_writes_nothing(two_bots, gateway_reload):
    assert _rpc("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN})["error"]["code"] == 4101
    swapped = _connect(bot_token=APP_TOKEN, app_token=BOT_TOKEN)
    assert swapped["error"]["code"] == 4101 and "xoxb-" in swapped["error"]["message"]
    assert APP_TOKEN not in json.dumps(swapped) and BOT_TOKEN not in json.dumps(swapped)
    assert _connect(app_token="«redacted:xapp…abcd»")["error"]["code"] == 4101
    assert _connect(allowed_users=["not a member id"])["error"]["code"] == 4101
    assert _connect(allowed_users="U01ABC2DEF3")["error"]["code"] == 4101
    env_file = get_profile_dir("scout") / ".env"
    assert "SLACK_" not in (env_file.read_text() if env_file.exists() else "")
    assert gateway_reload["hot"] == [] and gateway_reload["restart"] == []


def test_an_unknown_bot_is_a_typed_not_found_error(two_bots, gateway_reload):
    assert _connect("ghost")["error"]["code"] == 4064
    assert _rpc("messaging.slack.status", {"profile": "ghost"})["error"]["code"] == 4064
    assert _rpc("messaging.slack.manifest", {"profile": "ghost"})["error"]["code"] == 4064


def test_connect_stores_the_tokens_for_that_bot_only_and_never_echoes_them(two_bots, gateway_reload):
    before = dict(os.environ)
    response = _connect(allowed_users=["U01ABC2DEF3"])
    assert "error" not in response, response
    assert BOT_TOKEN not in json.dumps(response) and APP_TOKEN not in json.dumps(response)
    result = response["result"]
    assert result["profile"] == "scout" and result["enabled"] is True and result["configured"] is True
    assert result["bot_token_set"] and result["app_token_set"] and result["allowed_users_set"]

    scout_env = _env_of("scout")
    assert scout_env["SLACK_BOT_TOKEN"] == BOT_TOKEN and scout_env["SLACK_APP_TOKEN"] == APP_TOKEN
    assert scout_env["SLACK_ALLOWED_USERS"] == "U01ABC2DEF3"
    pilot_env = get_profile_dir("pilot") / ".env"
    assert "SLACK_" not in (pilot_env.read_text() if pilot_env.exists() else "")
    assert "SLACK_BOT_TOKEN" not in load_env()
    assert dict(os.environ) == before

    pilot = _ok("messaging.slack.status", {"profile": "pilot"})
    assert pilot["profile"] == "pilot" and pilot["bot_token_set"] is False and pilot["enabled"] is False
    scout = _ok("messaging.slack.status", {"profile": "scout"})
    assert scout["bot_token_set"] is True and scout["configured"] is True
    assert BOT_TOKEN not in json.dumps(scout) and APP_TOKEN not in json.dumps(scout)


def test_connect_restarts_the_gateway_unless_a_running_multiplexer_hot_serves_it(two_bots, gateway_reload):
    result = _ok("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    assert result["hot_served"] is False and result["restart_started"] is True
    assert gateway_reload["restart"] == ["scout"]

    gateway_reload["hot_served"]["value"] = True
    result = _ok("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    assert result["hot_served"] is True and result["restart_started"] is False
    assert gateway_reload["restart"] == ["scout"]


def test_disconnect_removes_the_tokens_and_disables_the_adapter(two_bots, gateway_reload):
    _ok("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    result = _ok("messaging.slack.disconnect", {"profile": "scout"})
    assert result["bot_token_set"] is False and result["app_token_set"] is False and result["enabled"] is False
    env = _env_of("scout")
    assert "SLACK_BOT_TOKEN" not in env and "SLACK_APP_TOKEN" not in env
    assert BOT_TOKEN not in (get_profile_dir("scout") / ".env").read_text()


def test_the_manifest_is_named_after_the_bot_and_opens_slacks_create_page(two_bots):
    result = _ok("messaging.slack.manifest", {"profile": "scout"})
    assert result["bot_name"] == "Scout Prime"
    manifest = result["manifest"]
    assert manifest["display_information"]["name"] == "Scout Prime"
    assert manifest["features"]["bot_user"]["display_name"] == "Scout Prime"
    assert manifest["settings"]["socket_mode_enabled"] is True
    assert "slash_commands" not in manifest["features"]
    assert {"im:history", "app_mentions:read", "chat:write"} <= set(manifest["oauth_config"]["scopes"]["bot"])

    link = urlsplit(result["create_url"])
    assert (link.scheme, link.netloc, link.path) == ("https", "api.slack.com", "/apps")
    query = parse_qs(link.query)
    assert query["new_app"] == ["1"] and json.loads(query["manifest_json"][0]) == manifest
    assert len(result["create_url"]) < 6000

    pilot = _ok("messaging.slack.manifest", {"profile": "pilot"})
    assert pilot["bot_name"] == "pilot" and pilot["manifest"]["display_information"]["name"] == "pilot"
