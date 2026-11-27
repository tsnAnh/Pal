"""The production adapter control writes the bot's own .env through the messaging writer and
restarts the adapter through the same reload the Slack connect method uses."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from gateway import chat_install_runtime as runtime
from gateway import status as gateway_status
from hermes_cli.profiles import create_profile, get_profile_dir

TOKEN = "xoxb-fake-token-do-not-use"


@pytest.fixture
def bots(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    create_profile("scout", no_alias=True, no_skills=True)
    return home


def env_of(profile: str) -> dict[str, str]:
    path = get_profile_dir(profile) / ".env"
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line) if path.exists() else {}


def test_apply_writes_to_the_named_bot_and_clear_removes_it(bots):
    control = runtime.MessagingAdapterControl()
    control.apply_env("scout", "slack", {"SLACK_BOT_TOKEN": TOKEN, "SLACK_ALLOWED_USERS": "U01ABC2DEF3"}, [])
    assert env_of("scout")["SLACK_ALLOWED_USERS"] == "U01ABC2DEF3" and env_of("scout")["SLACK_BOT_TOKEN"] == TOKEN
    assert "SLACK_ALLOWED_USERS" not in env_of("default")
    control.apply_env("scout", "slack", {}, ["SLACK_BOT_TOKEN", "SLACK_ALLOWED_USERS"])
    assert env_of("scout").get("SLACK_BOT_TOKEN") is None and env_of("scout").get("SLACK_ALLOWED_USERS") is None


def test_reload_uses_the_slack_reload_with_the_bot_name(monkeypatch):
    seen = []

    def slack_reload(profile):
        seen.append(profile)
        return {"hot_served": True, "restart_started": False}

    monkeypatch.setattr("tui_gateway.methods_messaging_slack._slack_reload", slack_reload)
    runtime.MessagingAdapterControl().reload("scout")
    runtime.MessagingAdapterControl().reload("default")
    assert seen == ["scout", None]


@pytest.mark.parametrize("answer, expected", [
    ({"hot_served": True, "restart_started": False}, runtime.ReloadOutcome.live),
    ({"hot_served": False, "restart_started": True}, runtime.ReloadOutcome.restarting),
    ({"hot_served": False, "restart_started": False, "restart_busy": True}, runtime.ReloadOutcome.not_started),
    ({"hot_served": False, "restart_started": False, "restart_error": "spawn failed"}, runtime.ReloadOutcome.not_started),
])
def test_reload_reports_whether_the_adapter_came_up(monkeypatch, answer, expected):
    monkeypatch.setattr("tui_gateway.methods_messaging_slack._slack_reload", lambda profile: answer)
    assert runtime.MessagingAdapterControl().reload("scout") is expected


def test_a_bot_is_live_only_while_its_own_connector_reports_connected(bots, monkeypatch):
    monkeypatch.setattr("hermes_cli.web_routers.messaging.resolve_gateway_liveness", lambda **_: SimpleNamespace(running=True))
    monkeypatch.setattr(gateway_status, "multiplexer_liveness_for_profile",
                        lambda _home: (1, gateway_status.read_runtime_status(bots / "gateway_state.json") or {}))
    control = runtime.MessagingAdapterControl()
    gateway_status.write_runtime_status(platform="scout:slack", platform_state="connected")
    assert control.is_live("scout", "slack") is False
    control.apply_env("scout", "slack", {"SLACK_BOT_TOKEN": TOKEN, "SLACK_APP_TOKEN": "xapp-fake-token-do-not-use"}, [])
    assert control.is_live("scout", "slack") is True
    gateway_status.write_runtime_status(platform="scout:slack", platform_state="retrying")
    assert control.is_live("scout", "slack") is False
