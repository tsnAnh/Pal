from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server

CANARY = "canary-secret-7f3a91c2d4e85b60"
TELEGRAM_CANARY = f"123456789:{CANARY}ABCDEFGHIJKLMNOPQRSTU"


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL", "WEBHOOK_PORT", "WEBHOOK_SECRET"):
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    (get_profile_dir("scout") / ".env").write_text(f"TELEGRAM_BOT_TOKEN={TELEGRAM_CANARY}\nWEBHOOK_SECRET={CANARY}\n")
    return home


@pytest.fixture
def gateway(monkeypatch):
    from hermes_cli.web_routers import messaging

    state = {"running": False, "hot": False, "hot_calls": []}
    real = messaging._platform_payloads

    def payloads(scoped_dir, entries):
        rows = real(scoped_dir, entries)
        for row in rows:
            row["gateway_running"] = state["running"]
        return rows

    def hot(profile):
        state["hot_calls"].append(profile)
        return state["hot"]

    monkeypatch.setattr(messaging, "_platform_payloads", payloads)
    monkeypatch.setattr(messaging, "_notify_multiplexer_hot_serve", hot)
    return state


def _rpc(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _update(platform: str = "telegram", profile: str = "scout", **params) -> dict:
    return _rpc("messaging.settings.update", {"profile": profile, "platform": platform, **params})


def _platform(result: dict, platform_id: str) -> dict:
    return next(p for p in result["platforms"] if p["id"] == platform_id)


def _field(platform: dict, key: str) -> list[str]:
    return next(f["values"] for f in platform["fields"] if f["key"] == key)


def _env_text(profile: str) -> str:
    path = get_profile_dir(profile) / ".env"
    return path.read_text() if path.exists() else ""


def test_get_lists_non_secret_fields_and_credentials_as_set_flags(two_bots, gateway):
    result = _ok("messaging.settings.get", {"profile": "scout"})
    telegram = _platform(result, "telegram")
    assert {f["key"]: f["kind"] for f in telegram["fields"]} == {
        "TELEGRAM_ALLOWED_USERS": "allowlist", "TELEGRAM_HOME_CHANNEL": "home_channel"}
    assert {s["key"]: s["is_set"] for s in telegram["secrets"]}["TELEGRAM_BOT_TOKEN"] is True
    webhook = _platform(result, "webhook")
    assert [f["key"] for f in webhook["fields"]] == ["WEBHOOK_PORT"]
    assert {s["key"]: s["is_set"] for s in webhook["secrets"]} == {"WEBHOOK_SECRET": True}
    pilot = _platform(_ok("messaging.settings.get", {"profile": "pilot"}), "telegram")
    assert {s["key"]: s["is_set"] for s in pilot["secrets"]}["TELEGRAM_BOT_TOKEN"] is False


def test_secret_values_never_reach_a_response_or_a_log(two_bots, gateway, caplog):
    caplog.set_level(logging.DEBUG)
    responses = [
        _rpc("messaging.settings.get", {"profile": "scout"}),
        _update(fields={"TELEGRAM_ALLOWED_USERS": ["42"]}),
        _update(fields={"TELEGRAM_ALLOWED_USERS": ["nope"]}),
        _update(platform="webhook", fields={"WEBHOOK_PORT": ["8650"]}, enabled=True)]
    assert CANARY not in json.dumps(responses)
    assert CANARY not in caplog.text


def test_update_saves_allowlist_home_channel_port_and_toggle_for_that_bot_only(two_bots, gateway):
    result = _ok("messaging.settings.update", {
        "profile": "scout", "platform": "telegram",
        "fields": {"TELEGRAM_ALLOWED_USERS": ["123", "456", "123"], "TELEGRAM_HOME_CHANNEL": ["-100987"]}})
    assert result["changed"] is True
    assert _field(result["settings"], "TELEGRAM_ALLOWED_USERS") == ["123", "456"]
    env = _env_text("scout")
    assert "TELEGRAM_ALLOWED_USERS=123,456" in env and "TELEGRAM_HOME_CHANNEL=-100987" in env
    assert "TELEGRAM_" not in _env_text("pilot")

    web = _ok("messaging.settings.update", {
        "profile": "scout", "platform": "webhook", "enabled": True, "fields": {"WEBHOOK_PORT": ["8650"]}})
    assert web["settings"]["enabled"] is True and _field(web["settings"], "WEBHOOK_PORT") == ["8650"]
    assert "WEBHOOK_PORT=8650" in _env_text("scout")
    assert _platform(_ok("messaging.settings.get", {"profile": "pilot"}), "webhook")["enabled"] is False


def test_clearing_a_field_removes_it(two_bots, gateway):
    _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                       "fields": {"TELEGRAM_ALLOWED_USERS": ["123"]}})
    cleared = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                                 "fields": {"TELEGRAM_ALLOWED_USERS": []}})
    assert _field(cleared["settings"], "TELEGRAM_ALLOWED_USERS") == []
    assert "TELEGRAM_ALLOWED_USERS" not in _env_text("scout")


@pytest.mark.parametrize("platform,key,values,fragment", [
    ("telegram", "TELEGRAM_ALLOWED_USERS", ["12ab"], "numbers"),
    ("telegram", "TELEGRAM_HOME_CHANNEL", ["abc"], "numbers"),
    ("telegram", "TELEGRAM_HOME_CHANNEL", ["1", "2"], "one value"),
    ("slack", "SLACK_ALLOWED_USERS", ["alice"], "start with U or W"),
    ("slack", "SLACK_HOME_CHANNEL", ["general"], "start with C, D or G"),
    ("discord", "DISCORD_ALLOWED_USERS", ["me#1"], "numbers"),
    ("webhook", "WEBHOOK_PORT", ["0"], "1 to 65535"),
    ("webhook", "WEBHOOK_PORT", ["70000"], "1 to 65535"),
    ("webhook", "WEBHOOK_PORT", ["http"], "1 to 65535"),
    ("webhook", "WEBHOOK_PORT", [], None),
    ("telegram", "TELEGRAM_BOT_TOKEN", ["1:xx"], "cannot be changed here"),
    ("telegram", "NOT_A_SETTING", ["1"], "cannot be changed here"),
])
def test_invalid_values_get_field_level_errors_and_write_nothing(two_bots, gateway, platform, key, values, fragment):
    before = _env_text("scout")
    response = _update(platform=platform, fields={key: values})
    if fragment is None:
        assert "error" not in response
        return
    assert response["error"]["code"] == 4101
    assert fragment in response["error"]["data"]["fields"][key]
    assert _env_text("scout") == before


def test_one_bad_field_blocks_the_whole_update(two_bots, gateway):
    before = _env_text("scout")
    response = _update(fields={"TELEGRAM_ALLOWED_USERS": ["123"], "TELEGRAM_HOME_CHANNEL": ["bad"]})
    assert set(response["error"]["data"]["fields"]) == {"TELEGRAM_HOME_CHANNEL"}
    assert _env_text("scout") == before


def test_unknown_profile_and_platform_are_typed_errors_and_other_bots_are_untouched(two_bots, gateway):
    assert _rpc("messaging.settings.get", {"profile": "ghost"})["error"]["code"] == 4064
    assert _update(profile="ghost", fields={"TELEGRAM_ALLOWED_USERS": ["1"]})["error"]["code"] == 4064
    assert _update(platform="nonesuch")["error"]["code"] == 4103
    assert "ALLOWED" not in _env_text("pilot") and "ALLOWED" not in _env_text("scout")


def test_a_repeat_save_is_a_no_op(two_bots, gateway, monkeypatch):
    first = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                               "fields": {"TELEGRAM_ALLOWED_USERS": ["123"]}})
    assert first["changed"] is True
    from hermes_cli.web_routers import messaging

    def boom(*args, **kwargs):
        raise AssertionError("a repeat save must not write")

    monkeypatch.setattr(messaging, "save_env_value", boom)
    monkeypatch.setattr(messaging, "remove_env_value", boom)
    gateway["running"] = True
    again = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                               "fields": {"TELEGRAM_ALLOWED_USERS": ["123"]}})
    assert again["changed"] is False and again["restart_needed"] is False
    assert gateway["hot_calls"] == []


def test_a_failed_write_restores_every_earlier_value(two_bots, gateway, monkeypatch):
    _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                       "fields": {"TELEGRAM_ALLOWED_USERS": ["111"], "TELEGRAM_HOME_CHANNEL": ["222"]}})
    before = _env_text("scout")
    from hermes_cli.web_routers import messaging

    real = messaging.save_env_value

    def flaky(key, value):
        if key == "TELEGRAM_HOME_CHANNEL" and value == "999":
            raise OSError("disk full")
        return real(key, value)

    monkeypatch.setattr(messaging, "save_env_value", flaky)
    response = _update(fields={"TELEGRAM_ALLOWED_USERS": ["333"], "TELEGRAM_HOME_CHANNEL": ["999"]})
    assert response["error"]["code"] == 5102 and "Nothing was changed" in response["error"]["message"]
    assert _env_text("scout") == before
    shown = _platform(_ok("messaging.settings.get", {"profile": "scout"}), "telegram")
    assert _field(shown, "TELEGRAM_ALLOWED_USERS") == ["111"] and _field(shown, "TELEGRAM_HOME_CHANNEL") == ["222"]


def test_restart_needed_only_when_a_running_gateway_did_not_hot_serve_the_change(two_bots, gateway):
    stopped = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                                 "fields": {"TELEGRAM_ALLOWED_USERS": ["1"]}})
    assert stopped["gateway_running"] is False and stopped["restart_needed"] is False

    gateway["running"] = True
    needs = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                               "fields": {"TELEGRAM_ALLOWED_USERS": ["2"]}})
    assert needs["restart_needed"] is True and needs["hot_served"] is False

    gateway["hot"] = True
    served = _ok("messaging.settings.update", {"profile": "scout", "platform": "telegram",
                                                "fields": {"TELEGRAM_ALLOWED_USERS": ["3"]}})
    assert served["restart_needed"] is False and served["hot_served"] is True
    assert gateway["hot_calls"] == ["scout", "scout"]


def test_the_methods_are_bridged_with_read_and_control_verbs():
    from gateway.session_bot_settings_controls import VERBS
    from tui_gateway.contracts import CANONICAL_METHODS

    assert VERBS["messaging.settings.get"].scope == "session:read"
    assert VERBS["messaging.settings.update"].scope == "session:control"
    assert {"messaging.settings.get", "messaging.settings.update"} <= set(CANONICAL_METHODS)
