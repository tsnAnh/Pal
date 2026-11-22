"""Slack "Add to Slack" for a secondary bot, end to end: the chat.install.* RPCs, the real service and Slack
provider over a fake Slack HTTP transport, the OAuth redirect route and the adapter's own install events, with a
launch profile and a secondary bot profile sharing one Hermes root. The install must reach ``ready`` with the
secondary bot's own ``.env`` carrying the Slack tokens, and every Slack-side effect must land in that bot's
profile, never the launch profile's.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from agent.vault_store import VaultStore
from gateway import chat_install_runtime, control_socket
from gateway.chat_install_store import ChatInstallStore
from gateway.chat_slack.api import SlackApi
from gateway.chat_slack.provider import SlackProvider
from gateway.chat_slack.records import SlackRecords
from gateway.config import PlatformConfig
from hermes_cli.profiles import create_profile, get_profile_dir
from hermes_cli.web_routers import chat_install as route
from hermes_cli.web_routers import messaging
from plugins.platforms.slack import adapter_install_events as install_events
from plugins.platforms.slack.adapter import SlackAdapter
from tests.gateway.chat_install_harness import HTTPS, nonce_of
from tests.gateway.chat_slack.fake_slack import BOT_TOKEN, REFRESH, FakeSlack
from tests.tui_gateway.contracts.chat_provider_fakes import FIXED_NOW
from tools import slack_tools
from tui_gateway import chat_providers, server
from tui_gateway.chat_install import REDIRECT_PATH
from tui_gateway.contracts import chat_provider as wire

BOT = "scout"
TEAM = "T1"
APP_KEY = "xapp-1-A0SCOUT-4242-ScoutGuidedAppKeySecretValue"
SLACK_ENV_KEYS = ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_ALLOWED_USERS")
GUIDED = {"icon_ok": False, "app_token_ok": False, "redirect_ok": False}
CAP = wire.ProviderCapability


class LiveGateway:
    def __init__(self) -> None:
        self.up = True
        self.restarts: list[str | None] = []

    def query(self, home, verb, *, params=None, timeout=2.0):
        return {"reloaded": True, "connecting": True} if self.up and verb == "reload-platform" else None

    def restart(self, profile, *, what, label):
        self.restarts.append(profile)
        return {"restart_started": False, "restart_error": "gateway busy", "restart_busy": True}


class Rig:
    def __init__(self, tmp_path: Path, monkeypatch, slack: FakeSlack):
        self.home = tmp_path / ".hermes"
        self.home.mkdir()
        monkeypatch.setattr(Path, "home", lambda: tmp_path)
        monkeypatch.setenv("HERMES_HOME", str(self.home))
        monkeypatch.setattr(server, "_hermes_home", self.home)
        for key in SLACK_ENV_KEYS:
            monkeypatch.delenv(key, raising=False)
        create_profile(BOT, no_alias=True, no_skills=True)
        self.slack, self.gateway = slack, LiveGateway()
        monkeypatch.setattr(control_socket, "query_gateway_control", self.gateway.query)
        monkeypatch.setattr(messaging, "_restart_gateway_after", self.gateway.restart)
        monkeypatch.setattr(chat_install_runtime, "public_url_for", lambda _home: HTTPS)
        monkeypatch.setattr(chat_providers, "PROVIDER_FACTORIES", {"slack": self._provider})
        app = FastAPI()
        app.include_router(route.router)
        self.client = TestClient(app)
        self.vault = VaultStore(get_profile_dir(BOT) / "vault")
        self.config_item = self._secret("Slack configuration token", REFRESH)
        self.app_key_item = self._secret("Slack app key", APP_KEY)

    def _provider(self, **deps) -> SlackProvider:
        return SlackProvider(**deps, api=SlackApi(self.slack.transport, sleep=lambda _s: None),
                             clock=lambda: self.slack.now)

    def _secret(self, label: str, value: str) -> str:
        return self.vault.add_item("api_key", label, {"api_key": value}).id

    def rpc(self, method: str, **params) -> dict:
        return server.handle_request({"id": "1", "method": method, "params": {
            "profile": BOT, "provider_id": "slack", "workspace": "w1", **params}})

    def state(self, response: dict) -> wire.SetupState:
        assert "error" not in response, response["error"]
        return wire.SetupState.model_validate(response["result"]["state"])

    def status(self) -> wire.SetupState:
        return self.state(self.rpc("chat.install.status"))

    def advance(self, state: wire.SetupState, event: str, **extra) -> dict:
        return self.rpc("chat.install.advance", event=event, expected_revision=state.revision, **extra)

    def to_manual_or_allow(self) -> wire.SetupState:
        state = self.state(self.rpc("chat.install.begin"))
        assert state.step is wire.SetupStep.needs_credential
        return self.state(self.advance(state, "credential_saved", vault_item_id=self.config_item))

    def finish_manual_steps(self, state: wire.SetupState) -> wire.SetupState:
        while state.step is wire.SetupStep.needs_manual_step:
            extra = {"vault_item_id": self.app_key_item} if state.next_action.action_id == CAP.app_level_credential.value else {}
            state = self.state(self.advance(state, "manual_step_done", **extra))
        return state

    def to_allow(self) -> wire.SetupState:
        state = self.finish_manual_steps(self.to_manual_or_allow())
        assert state.step is wire.SetupStep.needs_allow
        return state

    def allow(self, state: wire.SetupState):
        return self.client.get(REDIRECT_PATH, params={"code": "code-from-slack", "state": nonce_of(state.next_action.link)})

    def install(self) -> wire.SetupState:
        page = self.allow(self.to_allow())
        assert page.status_code == 200
        ready = self.status()
        assert ready.step is wire.SetupStep.ready
        return ready

    def env_of(self, profile: str) -> dict[str, str]:
        path = get_profile_dir(profile) / ".env"
        lines = path.read_text().splitlines() if path.exists() else []
        return dict(line.split("=", 1) for line in lines if "=" in line)

    def records(self, profile: str) -> SlackRecords:
        return SlackRecords(get_profile_dir(profile) / "chat_slack" / "records.json")


@pytest.fixture
def rig(tmp_path, monkeypatch):
    def build(**slack_options) -> Rig:
        return Rig(tmp_path, monkeypatch, FakeSlack(now=FIXED_NOW, **slack_options))
    return build


def test_secondary_bot_install_reaches_ready_with_a_live_adapter_in_its_own_profile(rig):
    r = rig()
    ready = r.install()
    assert ready.installation_id is not None
    env = r.env_of(BOT)
    assert env["SLACK_BOT_TOKEN"] == BOT_TOKEN and env["SLACK_APP_TOKEN"].startswith("xapp-")
    assert env["SLACK_ALLOWED_USERS"] == "UOWNER"
    assert not any(key in r.env_of("default") for key in SLACK_ENV_KEYS)
    assert r.records(BOT).app(BOT, "w1")["bot_token_item_id"] and not (r.home / "chat_slack").exists()


def test_slack_tools_of_a_secondary_bot_find_its_install_under_that_profile_scope(rig):
    r = rig()
    r.install()
    with messaging._profile_scope(BOT):
        found = slack_tools.active_install(BOT)
        assert found is not None and found.team_id == TEAM
        assert slack_tools.check_slack_tools() is True
        assert slack_tools._bot_token(found) == BOT_TOKEN
    assert slack_tools.active_install(BOT) is None


def test_the_pasted_app_key_is_stored_for_the_adapter(rig):
    r = rig(**GUIDED)
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.needs_manual_step
    state = r.finish_manual_steps(state)
    assert state.step is wire.SetupStep.needs_allow
    assert r.records(BOT).app(BOT, "w1")["app_token_item_id"] == r.app_key_item


def test_guided_install_delivers_the_pasted_app_key_to_the_bots_env(rig):
    r = rig(**GUIDED)
    assert r.allow(r.to_allow()).status_code == 200
    assert r.status().step is wire.SetupStep.ready
    assert r.env_of(BOT)["SLACK_APP_TOKEN"] == APP_KEY


def test_app_key_step_without_a_key_is_refused_and_changes_nothing(rig):
    r = rig(**GUIDED)
    state = r.to_manual_or_allow()
    while state.next_action.action_id != CAP.app_level_credential.value:
        state = r.state(r.advance(state, "manual_step_done"))
    response = r.advance(state, "manual_step_done", manual_step="app_level_credential")
    assert response["error"]["data"]["reason"] == "invalid_event"
    assert r.status() == state


def test_a_pasted_value_that_is_not_an_app_key_is_rejected_and_the_step_can_be_retried(rig):
    r = rig(**GUIDED)
    state = r.to_manual_or_allow()
    while state.next_action.action_id != CAP.app_level_credential.value:
        state = r.state(r.advance(state, "manual_step_done"))
    wrong = r._secret("Slack app key", BOT_TOKEN)
    failed = r.state(r.advance(state, "manual_step_done", vault_item_id=wrong))
    assert failed.step is wire.SetupStep.error and failed.error.code is wire.SetupErrorCode.credential_rejected
    retried = r.state(r.advance(failed, "retry"))
    assert retried.step is wire.SetupStep.needs_manual_step
    assert retried.next_action.action_id == CAP.app_level_credential.value
    assert "app_token_item_id" not in r.records(BOT).app(BOT, "w1")


def test_redirect_completes_the_install_in_the_bots_profile(rig):
    r = rig()
    page = r.allow(r.to_allow())
    assert page.status_code == 200 and "Done" in page.text
    assert r.status().step is wire.SetupStep.ready
    assert r.records(BOT).app(BOT, "w1")["team_id"] == TEAM
    assert not (r.home / "chat_slack").exists()


def test_a_failed_exchange_after_the_link_is_used_is_not_reported_as_done(rig):
    r = rig()
    state = r.to_allow()
    r.slack.fail["oauth.v2.access"] = "internal_error"
    page = r.allow(state)
    assert page.status_code == 500 and "Done" not in page.text and "Return to Pal" in page.text
    failed = r.status()
    assert failed.step is wire.SetupStep.error and failed.error.code is wire.SetupErrorCode.install_failed


def test_probe_at_credential_time_makes_the_setup_automatic_when_the_workspace_allows(rig):
    r = rig()
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.needs_allow and state.manual_steps_done == []
    manifest = r.slack.apps[state.app_id]
    assert manifest["oauth_config"]["redirect_urls"] == [HTTPS + REDIRECT_PATH]
    assert r.records(BOT).app(BOT, "w1")["app_token_item_id"]
    assert r.records(BOT).workspace("w1")["capabilities"]["set_icon"] == "automatic"
    assert r.slack.created == 2 and list(r.slack.apps) == [state.app_id]


def test_probe_findings_keep_what_the_workspace_refuses_guided(rig):
    r = rig(icon_ok=True, app_token_ok=False, redirect_ok=False)
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.needs_manual_step
    pending = [state.next_action.action_id]
    while state.step is wire.SetupStep.needs_manual_step:
        state = r.state(r.advance(state, "manual_step_done", **(
            {"vault_item_id": r.app_key_item} if state.next_action.action_id == "app_level_credential" else {})))
        pending.append(state.next_action.action_id)
    assert pending[:2] == ["app_level_credential", "gateway_redirect"]
    assert "redirect_urls" not in r.slack.apps[state.app_id]["oauth_config"]


def test_a_probe_that_cannot_finish_leaves_setup_guided_instead_of_failing(rig):
    r = rig()
    r.slack.fail["apps.manifest.validate"] = "internal_error"
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.needs_manual_step
    assert "set_icon" not in r.records(BOT).workspace("w1").get("capabilities", {})


def test_an_expired_config_credential_surfaces_at_credential_time(rig):
    r = rig()
    r.slack.fail["tooling.tokens.rotate"] = "invalid_refresh_token"
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.error and state.error.code is wire.SetupErrorCode.credential_expired


def test_setup_is_not_ready_while_the_adapter_never_came_up_and_retry_finishes_it(rig):
    r = rig()
    state = r.to_allow()
    r.gateway.up = False
    page = r.allow(state)
    assert page.status_code == 500 and "Done" not in page.text
    failed = r.status()
    assert failed.step is wire.SetupStep.error and failed.error.code is wire.SetupErrorCode.install_failed
    assert r.gateway.restarts == [BOT]
    r.gateway.up = True
    done = r.state(r.advance(failed, "retry"))
    assert done.step is wire.SetupStep.ready
    assert r.env_of(BOT)["SLACK_BOT_TOKEN"] == BOT_TOKEN


def test_reinstall_after_revoke_opens_a_fresh_app_not_the_deleted_one(rig):
    r = rig()
    first = r.install()
    revoked = r.state(r.rpc("chat.install.revoke"))
    assert revoked.step is wire.SetupStep.revoked and revoked.app_id is None and revoked.installation_id is None
    assert r.slack.apps == {}
    assert not any(key in r.env_of(BOT) for key in SLACK_ENV_KEYS)
    state = r.to_manual_or_allow()
    assert state.step is wire.SetupStep.needs_allow and state.app_id is not None
    link_app = parse_qs(urlsplit(state.next_action.link).query)["app"][0]
    assert link_app == state.app_id and link_app in r.slack.apps
    assert r.allow(state).status_code == 200
    again = r.status()
    assert again.step is wire.SetupStep.ready and again.installation_id == first.installation_id
    assert r.env_of(BOT)["SLACK_BOT_TOKEN"] == BOT_TOKEN


def slack_adapter(team_bot_user: str = "UBOT") -> SlackAdapter:
    adapter = SlackAdapter(PlatformConfig(enabled=True, token="xoxb-fake-token"))
    adapter._app = MagicMock()
    adapter._app.client = AsyncMock()
    adapter._owner_profile = BOT
    adapter._bot_user_id = team_bot_user
    adapter._team_bot_user_ids = {TEAM: team_bot_user}
    adapter._team_clients = {TEAM: AsyncMock()}
    adapter._running = True
    adapter._fatal_error_handler = AsyncMock()
    return adapter


@pytest.mark.asyncio
async def test_uninstalling_the_app_in_slack_revokes_the_bots_install_and_stops_its_adapter(rig):
    r = rig()
    ready = r.install()
    adapter = slack_adapter()
    await install_events.on_app_uninstalled(adapter, {"type": "app_uninstalled"}, {"team_id": TEAM})
    store = ChatInstallStore(r.home)
    assert store.installation(ready.installation_id).status is wire.InstallationStatus.revoked
    assert r.status().step is wire.SetupStep.revoked and r.status().app_id is None
    assert not any(key in r.env_of(BOT) for key in SLACK_ENV_KEYS)
    assert r.slack.apps == {} and r.records(BOT).app(BOT, "w1") == {}
    adapter._fatal_error_handler.assert_awaited_once_with(adapter)
    assert adapter.fatal_error_code == "installation_revoked" and adapter.fatal_error_retryable is False
    await install_events.on_app_uninstalled(adapter, {"type": "app_uninstalled"}, {"team_id": TEAM})
    adapter._fatal_error_handler.assert_awaited_once()


@pytest.mark.asyncio
async def test_tokens_revoked_for_the_bot_ends_the_install_but_a_user_token_does_not(rig):
    r = rig()
    ready = r.install()
    adapter = slack_adapter()
    await install_events.on_tokens_revoked(adapter, {"type": "tokens_revoked", "tokens": {"oauth": ["UOWNER"], "bot": []}},
                                           {"team_id": TEAM})
    assert r.status().step is wire.SetupStep.ready
    adapter._fatal_error_handler.assert_not_awaited()
    await install_events.on_tokens_revoked(adapter, {"type": "tokens_revoked", "tokens": {"oauth": [], "bot": ["UBOT"]}},
                                           {"team_id": TEAM})
    assert ChatInstallStore(r.home).installation(ready.installation_id).status is wire.InstallationStatus.revoked
    assert r.status().step is wire.SetupStep.revoked
    adapter._fatal_error_handler.assert_awaited_once_with(adapter)


@pytest.mark.asyncio
async def test_another_workspaces_uninstall_event_leaves_the_install_alone(rig):
    r = rig()
    r.install()
    adapter = slack_adapter()
    await install_events.on_app_uninstalled(adapter, {"type": "app_uninstalled"}, {"team_id": "T9"})
    assert r.status().step is wire.SetupStep.ready
    adapter._fatal_error_handler.assert_not_awaited()
