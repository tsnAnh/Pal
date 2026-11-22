"""A chat sender whose bot cannot reach its model gets a short product-language reply, never operator copy.

Drives the real runner, session authority and turn loop with a temp ``HERMES_HOME`` that holds no
provider credentials; only the Slack transport is a recording stand-in.
"""

import asyncio
from dataclasses import replace

import pytest

from gateway.audience.model import Audience, SenderFacts
from gateway.chat_install_store import ChatInstallStore
from gateway.config import GatewayConfig, Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent
from gateway.run import GatewayRunner
from gateway.session_authority import initialize_session_authority
from persistence_assembly import close_stores_under
from tests.waiting import async_wait_until
from tui_gateway.contracts.chat_provider import Installation, InstallationStatus

MEMBER_REPLY = "I can't answer right now."
OWNER_REPLY = "I can't reach my model right now. Sign in to the model again in Pal."
OPERATOR_WORDS = ("/login", "/retry", "/new", "hermes", "provider", "openai", "openrouter", "codex", "api key", "http")
NO_LOGIN_PROVIDERS = ("openai-codex", "openrouter")


class SlackStandIn(BasePlatformAdapter):
    def __init__(self):
        super().__init__(PlatformConfig(enabled=True, token="x"), Platform.SLACK)
        self.sent: list[str] = []

    async def connect(self, *, is_reconnect=False):
        return True

    async def disconnect(self):
        return None

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append(content)
        return SendResult(success=True, message_id="m")

    async def send_typing(self, *args, **kwargs):
        return None

    async def get_chat_info(self, chat_id):
        return {"id": chat_id}


def install_pal_bot(home):
    ChatInstallStore(home).save_installation(Installation(
        id="slack-T1-default", provider_id="slack", bot="default", workspace_id="T1", workspace_name="Acme",
        status=InstallationStatus.active, created_at=1.0, updated_at=1.0, vault_item_ids=[]), [], "UOWNER")


async def reply_to(monkeypatch, tmp_path, *, provider, audience, pal_install):
    import gateway.run as gateway_run
    import hermes_yaml as yaml
    home = tmp_path / ".hermes"
    home.mkdir()
    (home / "config.yaml").write_text(yaml.safe_dump({
        "model": {"provider": provider, "default": "m"},
        "platforms": {"slack": {"audience": {"policy": "workspace"}}}}))
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("SLACK_ALLOWED_USERS", "UOWNER")
    monkeypatch.setattr(gateway_run, "_hermes_home", home)
    if pal_install:
        install_pal_bot(home)
    runner = GatewayRunner(GatewayConfig(sessions_dir=tmp_path / "sessions"))
    adapter = SlackStandIn()
    adapter.gateway_runner, runner.adapters = runner, {Platform.SLACK: adapter}
    authority = await initialize_session_authority(runner, profile_id="default", instance_id="failure-reply")
    runner._wire_adapter_handlers(adapter)
    sender = "U1" if audience is Audience.MEMBER else "UOWNER"
    source = replace(adapter.build_source(chat_id="D1", user_id=sender, chat_type="dm"), audience=audience)
    if audience is Audience.MEMBER:
        source._sender_facts = SenderFacts(user_id=sender, scope_id="T1", same_scope=True, is_bot=False,
                                           is_restricted=False, display_name="Alice")
    try:
        await adapter.handle_message(MessageEvent(text="hello", source=source, message_id="1"))
        await async_wait_until(lambda: any("⚠" in text or text.startswith("I can't") for text in adapter.sent),
                               timeout=60, what="the failure reply")
        await asyncio.gather(*adapter._background_tasks)
        return [text for text in adapter.sent if "home channel" not in text]
    finally:
        close_stores_under(authority.persistence.scope.profile_dir)


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", NO_LOGIN_PROVIDERS)
async def test_a_coworker_gets_a_generic_line_that_names_no_provider_or_command(monkeypatch, tmp_path, provider):
    sent = await reply_to(monkeypatch, tmp_path, provider=provider, audience=Audience.MEMBER, pal_install=True)
    assert sent == [MEMBER_REPLY]
    assert not [word for word in OPERATOR_WORDS if word in sent[0].lower()]


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", NO_LOGIN_PROVIDERS)
@pytest.mark.parametrize("pal_install", [True, False])
async def test_the_owner_of_a_pal_bot_is_told_to_sign_in_again_and_other_owners_keep_the_host_copy(
        monkeypatch, tmp_path, provider, pal_install):
    sent = await reply_to(monkeypatch, tmp_path, provider=provider, audience=Audience.OWNER, pal_install=pal_install)
    assert len(sent) == 1
    if pal_install:
        assert sent == [OWNER_REPLY]
    else:
        assert OWNER_REPLY not in sent and sent[0].startswith("⚠️")


@pytest.mark.asyncio
@pytest.mark.parametrize("audience, expected_start", [(Audience.MEMBER, MEMBER_REPLY), (Audience.OWNER, "⚠️")])
async def test_the_last_resort_turn_error_notice_is_generic_for_a_coworker(audience, expected_start):
    adapter = SlackStandIn()
    source = replace(adapter.build_source(chat_id="D1", user_id="U1", chat_type="dm"), audience=audience)
    await adapter._notify_turn_error(MessageEvent(text="hello", source=source, message_id="1"), RuntimeError("boom"))
    assert len(adapter.sent) == 1 and adapter.sent[0].startswith(expected_start)
    assert audience is not Audience.MEMBER or adapter.sent == [MEMBER_REPLY]
