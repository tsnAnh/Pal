"""Slack setup applies to the running gateway without a restart.

Connect, finish (the chat-install redirect) and disconnect each save the bot's ``.env`` and ask the
gateway that owns the profile to rebuild just that Slack adapter over the control socket. The fixture
answers that verb the way a live gateway does and answers no multiplexer rescan, so the old
hot-serve-or-restart code (which only knew a named profile served by a multiplexer) took the restart
branch for the ``default`` profile and for a profile with its own gateway.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from gateway import control_socket
from hermes_cli.profiles import create_profile, get_profile_dir
from hermes_cli.web_routers import chat_install as route
from hermes_cli.web_routers import messaging
from tests.gateway.chat_install_harness import nonce_of, register_fakes
from tests.tui_gateway.contracts.chat_provider_fakes import AuthorizeOnlyFake
from tui_gateway import server

BOT_TOKEN = "xoxb-1111111111-2222222222-ScoutBotTokenSecretValue"
APP_TOKEN = "xapp-1-A0ABCDEFGH-3333333333-ScoutAppTokenSecretValue"
SLACK_ENV_KEYS = {"SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_ALLOWED_USERS"}


class SlackFake(AuthorizeOnlyFake):
    provider_id = "slack"
    caps = AuthorizeOnlyFake.caps.model_copy(update={"provider_id": "slack"})
    allowed_users_env = "SLACK_ALLOWED_USERS"

    def authorizing_identity(self, installation):
        return "U01ABC2DEF3"

    def adapter_env(self, installation):
        return {"SLACK_BOT_TOKEN": BOT_TOKEN, "SLACK_APP_TOKEN": APP_TOKEN}


class LiveGateway:
    def __init__(self) -> None:
        self.verbs: list[tuple[str, str, dict]] = []
        self.restarts: list[str | None] = []

    def query(self, home, verb, *, params=None, timeout=2.0):
        self.verbs.append((str(home), verb, dict(params or {})))
        return {"reloaded": True, "connecting": True} if verb == "reload-platform" else None

    def reloads(self) -> list[dict]:
        return [params for _home, verb, params in self.verbs if verb == "reload-platform"]


@pytest.fixture
def live(tmp_path, monkeypatch) -> LiveGateway:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in SLACK_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    gateway = LiveGateway()
    monkeypatch.setattr(control_socket, "query_gateway_control", gateway.query)

    def restart(profile, *, what, label):
        gateway.restarts.append(profile)
        return {"restart_started": True}

    monkeypatch.setattr(messaging, "_restart_gateway_after", restart)
    return gateway


def rpc(method: str, params: dict) -> dict:
    response = server.handle_request({"id": "1", "method": method, "params": params})
    assert "error" not in response, response["error"]
    return response["result"]


def profile_params(profile: str) -> dict:
    return {} if profile == "default" else {"profile": profile}


@pytest.mark.parametrize("profile", ["default", "scout"])
def test_connect_and_disconnect_reload_the_adapter_without_a_restart(live, profile):
    connected = rpc("messaging.slack.connect", {**profile_params(profile), "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    assert connected["restart_started"] is False and connected["hot_served"] is True
    disconnected = rpc("messaging.slack.disconnect", profile_params(profile))
    assert disconnected["restart_started"] is False and disconnected["hot_served"] is True
    assert live.restarts == []
    home = str(get_profile_dir(profile))
    assert [(r["platform"], r["home"]) for r in live.reloads()] == [("slack", home), ("slack", home)]
    assert SLACK_ENV_KEYS <= set(live.reloads()[0]["env_keys"])


@pytest.fixture
def install(live, monkeypatch):
    register_fakes(monkeypatch, SlackFake())
    monkeypatch.setattr("gateway.chat_install_runtime.public_url_for", lambda _home: "https://pal.example.test")
    app = FastAPI()
    app.include_router(route.router)
    return TestClient(app)


def chat(method: str, **params) -> dict:
    return rpc(method, {"workspace": "w1", **params})


def test_finishing_and_revoking_the_chat_install_never_restart_the_gateway(live, install):
    state = chat("chat.install.begin", provider_id="slack")["state"]
    link = state["next_action"]["link"]
    page = install.get("/webapp/chat-install/callback", params={"code": "code-from-slack", "state": nonce_of(link)})
    assert page.status_code == 200
    assert chat("chat.install.status", provider_id="slack")["state"]["step"] == "ready"
    assert len(live.reloads()) == 1
    chat("chat.install.revoke", provider_id="slack")
    assert len(live.reloads()) == 2
    assert live.restarts == []
