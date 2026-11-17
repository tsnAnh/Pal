"""Slack adapter side of a chat install: bindings follow the bot's own membership events, the welcome
and the channel hello go out once, and a user the install did not allow never reaches the agent."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from gateway.chat_install_store import ChatInstallStore
from gateway.config import PlatformConfig
from gateway.platforms.base import SendResult
from plugins.platforms.slack import adapter_install_events as events
from plugins.platforms.slack.adapter import SlackAdapter
from tests.gateway.chat_install_harness import RecordingControl
from tui_gateway.chat_install import initial_state
from tui_gateway.contracts import chat_provider as wire

pytestmark = pytest.mark.asyncio

TEAM, BOT_USER, OWNER = "T1", "U_BOT", "U_OWNER"
INSTALL_ID = "slack-install-default-T1"


@pytest.fixture
def home(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr("gateway.platforms.base.DOCUMENT_CACHE_DIR", tmp_path / "doc_cache")
    return home


@pytest.fixture
def store(home):
    store = ChatInstallStore(home)
    installation = wire.Installation(
        id=INSTALL_ID, provider_id="slack", bot="default", workspace_id=TEAM, workspace_name="Team",
        status=wire.InstallationStatus.active, created_at=1.0, updated_at=1.0, vault_item_ids=["v"],
        owner_user_id=OWNER)
    store.save_installation(installation, ["SLACK_BOT_TOKEN", "SLACK_ALLOWED_USERS"])
    state = initial_state("default", "slack", "", 1.0).model_copy(
        update={"step": wire.SetupStep.ready, "revision": 1, "installation_id": INSTALL_ID})
    store.save(state, 0)
    return store


@pytest.fixture
def adapter(home):
    adapter = SlackAdapter(PlatformConfig(enabled=True, token="xoxb-fake-token"))
    adapter._app = MagicMock()
    adapter._app.client = AsyncMock()
    adapter._bot_user_id = BOT_USER
    adapter._team_bot_user_ids = {TEAM: BOT_USER}
    adapter._team_clients = {TEAM: AsyncMock()}
    adapter._running = True
    adapter.handle_message = AsyncMock()
    adapter.send = AsyncMock(return_value=SendResult(success=True, message_id="1"))
    return adapter


def joined(channel="C1", user=BOT_USER, team=TEAM):
    return {"type": "member_joined_channel", "user": user, "channel": channel, "team": team}


def revisions(store) -> list[int]:
    return [state.revision for _, state in store.events_after(0)]


async def test_bot_joining_a_known_channel_lights_the_binding_once_and_emits(adapter, store):
    store.set_binding(INSTALL_ID, "C1", "default", False, False)
    before = len(store.events_after(0))
    await events.on_member_joined(adapter, joined(), {})
    await events.on_member_joined(adapter, joined(), {})
    assert store.binding(INSTALL_ID, "C1").live is True
    assert len(store.events_after(0)) == before + 1
    adapter.send.assert_not_awaited()


async def test_unknown_channel_other_user_and_other_workspace_are_ignored(adapter, store):
    store.set_binding(INSTALL_ID, "C1", "default", False, False)
    before = len(store.events_after(0))
    await events.on_member_joined(adapter, joined(channel="C_UNKNOWN"), {})
    await events.on_member_joined(adapter, joined(user="U_SOMEONE"), {})
    await events.on_member_joined(adapter, joined(team="T_OTHER"), {})
    assert store.binding(INSTALL_ID, "C1").live is False
    assert len(store.events_after(0)) == before


async def test_hello_goes_out_once_and_only_when_requested(adapter, store):
    store.set_binding(INSTALL_ID, "C_HELLO", "default", True, True)
    store.set_binding(INSTALL_ID, "C_QUIET", "default", True, False)
    for channel in ("C_HELLO", "C_HELLO", "C_QUIET"):
        await events.on_member_joined(adapter, joined(channel=channel), {})
    adapter.send.assert_awaited_once()
    assert adapter.send.await_args.args[0] == "C_HELLO" and "default" in adapter.send.await_args.args[1]


async def test_failed_hello_is_released_so_the_next_join_retries(adapter, store):
    store.set_binding(INSTALL_ID, "C1", "default", True, True)
    adapter.send.return_value = SendResult(success=False, error="x")
    await events.on_member_joined(adapter, joined(), {})
    adapter.send.return_value = SendResult(success=True, message_id="2")
    await events.on_member_joined(adapter, joined(), {})
    await events.on_member_joined(adapter, joined(), {})
    assert adapter.send.await_count == 2


async def test_member_left_turns_the_binding_off_and_emits(adapter, store):
    store.set_binding(INSTALL_ID, "C1", "default", True, False)
    before = len(store.events_after(0))
    await events.on_member_left(adapter, {**joined(), "type": "member_left_channel"}, {})
    await events.on_member_left(adapter, {**joined(), "type": "member_left_channel"}, {})
    assert store.binding(INSTALL_ID, "C1").live is False
    assert len(store.events_after(0)) == before + 1


async def test_welcome_dm_goes_to_the_owner_once_and_is_released_on_failure(adapter, store):
    adapter.send.return_value = SendResult(success=False, error="x")
    await events.send_install_welcomes(adapter)
    adapter.send.return_value = SendResult(success=True, message_id="1")
    await events.send_install_welcomes(adapter)
    await events.send_install_welcomes(adapter)
    assert adapter.send.await_count == 2
    assert adapter.send.await_args.args[0] == OWNER and "Message me here" in adapter.send.await_args.args[1]


async def test_welcome_waits_for_a_known_installation(adapter, home):
    await events.send_install_welcomes(adapter)
    adapter.send.assert_not_awaited()


def slack_event(channel, user, ts, text="<@U_BOT> hi"):
    return {"channel": channel, "channel_type": "channel", "user": user, "text": text, "ts": ts, "team": TEAM}


async def test_only_the_owner_reaches_the_agent_and_channels_never_share_a_session(adapter, store, monkeypatch):
    from gateway.run import GatewayRunner
    from gateway.session import Platform

    control = RecordingControl()
    control.apply_env("default", "slack", {"SLACK_ALLOWED_USERS": OWNER}, [])
    for key, value in control.applied[0][2].items():
        monkeypatch.setenv(key, value)
    for var in ("SLACK_ALLOW_ALL_USERS", "GATEWAY_ALLOW_ALL_USERS", "GATEWAY_ALLOWED_USERS", "SLACK_ALLOW_BOTS"):
        monkeypatch.delenv(var, raising=False)
    runner = object.__new__(GatewayRunner)
    runner.pairing_store = MagicMock(is_approved=lambda *a, **k: False)
    adapter._message_handler = runner._is_user_authorized
    reaching = []
    adapter.handle_message = AsyncMock(side_effect=reaching.append)
    with patch.object(adapter, "_resolve_user_name", new=AsyncMock(return_value="someone")):
        await adapter._handle_slack_message(slack_event("C1", "U_STRANGER", "1700000000.000001"))
        assert reaching == []
        await adapter._handle_slack_message(slack_event("C1", OWNER, "1700000000.000002"))
        await adapter._handle_slack_message(slack_event("C2", OWNER, "1700000000.000003"))
    assert [e.source.user_id for e in reaching] == [OWNER, OWNER]
    assert all(e.source.platform is Platform.SLACK for e in reaching)
    first, second = (adapter._source_session_key(e.source) for e in reaching)
    assert first != second
