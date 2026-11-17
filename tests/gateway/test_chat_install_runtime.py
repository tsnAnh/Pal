"""The production adapter control writes the bot's own .env through the messaging writer and
restarts the adapter through the same reload the Slack connect method uses."""

from __future__ import annotations

from pathlib import Path

import pytest

from gateway import chat_install_runtime as runtime
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
    monkeypatch.setattr("tui_gateway.methods_messaging_slack._slack_reload", seen.append)
    runtime.MessagingAdapterControl().reload("scout")
    runtime.MessagingAdapterControl().reload("default")
    assert seen == ["scout", None]
