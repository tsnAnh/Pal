from __future__ import annotations

import logging
from dataclasses import dataclass

import pytest

from gateway.chat_discord.api import DiscordSetupError
from tests.gateway.chat_discord.discord_kit import BOT, Kit
from tests.gateway.chat_discord.fake_discord import (
    ADMINISTRATOR,
    GUILD_ID,
    MANAGE_CHANNELS,
    MANAGE_WEBHOOKS,
    TOKEN,
)
from tui_gateway.contracts import chat_provider as wire

CODE = wire.SetupErrorCode
FIX = wire.FixAction
OTHER_GUILD = "100000000000000009"


@dataclass(frozen=True)
class Failure:
    code: wire.SetupErrorCode
    fix: wire.FixAction
    reason: str
    permissions: tuple[str, ...] = ()
    retry_after: int | None = None
    workspace: str = GUILD_ID


def unauthorized(kit: Kit) -> None:
    kit.fake.reject_auth = True


def no_saved_token(kit: Kit) -> None:
    kit.token = None


def guild_unknown(kit: Kit) -> None:
    kit.fake.hidden_guilds.add(GUILD_ID)


def guild_forbidden(kit: Kit) -> None:
    kit.fake.forbidden_guilds.add(GUILD_ID)


def intent_off(kit: Kit) -> None:
    kit.fake.intent_enabled = False


def permissions(bits: int):
    def apply(kit: Kit) -> None:
        kit.fake.permissions = bits
    return apply


def switch(name: str, value=True):
    def apply(kit: Kit) -> None:
        setattr(kit.fake, name, value)
    return apply


def guilds(*ids: str):
    def apply(kit: Kit) -> None:
        kit.fake.guild_ids = list(ids)
    return apply


FAILURES = {
    "unauthorized": (unauthorized, Failure(CODE.credential_rejected, FIX.reenter_credential, "invalid_token")),
    "no_saved_token": (no_saved_token, Failure(CODE.credential_rejected, FIX.reenter_credential, "no_token")),
    "guild_unknown": (guild_unknown, Failure(CODE.allow_denied, FIX.restart_allow, "bot_not_in_server")),
    "guild_forbidden": (guild_forbidden, Failure(CODE.allow_denied, FIX.restart_allow, "bot_not_in_server")),
    "intent_off": (intent_off, Failure(CODE.install_failed, FIX.retry, "missing_intent")),
    "no_manage_channels": (permissions(MANAGE_WEBHOOKS), Failure(
        CODE.install_failed, FIX.retry, "missing_permission", ("Manage Channels",))),
    "no_manage_webhooks": (permissions(MANAGE_CHANNELS), Failure(
        CODE.install_failed, FIX.retry, "missing_permission", ("Manage Webhooks",))),
    "no_permissions": (permissions(0), Failure(
        CODE.install_failed, FIX.retry, "missing_permission", ("Manage Channels", "Manage Webhooks"))),
    "channel_create_denied": (switch("deny_channel_create"), Failure(
        CODE.install_failed, FIX.retry, "missing_permission", ("Manage Channels",))),
    "webhook_create_denied": (switch("deny_webhook_create"), Failure(
        CODE.install_failed, FIX.retry, "missing_permission", ("Manage Webhooks",))),
    "rate_limited_twice": (switch("rate_limits", 2), Failure(CODE.provider_unreachable, FIX.retry, "rate_limited", (), 1)),
    "network_down": (switch("network_down"), Failure(CODE.provider_unreachable, FIX.retry, "network")),
    "server_error": (switch("server_error"), Failure(CODE.provider_unreachable, FIX.retry, "http_500")),
    "no_servers": (guilds(), Failure(CODE.allow_denied, FIX.restart_allow, "bot_not_in_server", workspace="")),
    "two_servers": (guilds(GUILD_ID, OTHER_GUILD), Failure(CODE.install_failed, FIX.retry, "choose_server", workspace="")),
}


@pytest.fixture(params=sorted(FAILURES))
def scenario(request, kit):
    setup, expected = FAILURES[request.param]
    setup(kit)
    return kit, expected


def test_provider_raises_the_expected_setup_error(scenario):
    kit, expected = scenario
    with pytest.raises(DiscordSetupError) as raised:
        kit.install(workspace=expected.workspace)
    error = raised.value
    assert (error.code, error.fix, error.reason, error.permissions, error.retry_after_seconds) == (
        expected.code, expected.fix, expected.reason, expected.permissions, expected.retry_after)


def test_service_reports_the_expected_error_state(scenario):
    kit, expected = scenario
    state, installation = kit.service().begin(BOT, "discord", expected.workspace)
    assert (state.step, installation) == (wire.SetupStep.error, None)
    assert (state.error.code, state.error.fix, state.error.reason, tuple(state.error.permissions),
            state.error.retry_after_seconds) == (expected.code, expected.fix, expected.reason,
                                                 expected.permissions, expected.retry_after)


def test_failure_text_and_logs_never_contain_the_token(scenario, caplog):
    kit, expected = scenario
    caplog.set_level(logging.DEBUG)
    with pytest.raises(DiscordSetupError) as raised:
        kit.install(workspace=expected.workspace)
    kit.service().begin(BOT, "discord", expected.workspace)
    assert TOKEN not in str(raised.value) and TOKEN not in repr(raised.value) and TOKEN not in caplog.text


def test_failed_install_leaves_no_route_or_vault_item_behind(scenario):
    kit, expected = scenario
    with pytest.raises(DiscordSetupError):
        kit.install(workspace=expected.workspace)
    assert (kit.routes(), kit.vault.list_items()) == ([], [])


def test_administrator_passes_without_the_named_permissions(kit):
    kit.fake.permissions = ADMINISTRATOR
    assert kit.install().workspace_id == GUILD_ID


def test_both_permissions_pass(kit):
    kit.fake.permissions = MANAGE_CHANNELS | MANAGE_WEBHOOKS
    assert kit.install().bot == BOT


def test_one_rate_limit_waits_for_retry_after_then_succeeds(kit):
    kit.fake.rate_limits = 1
    installation = kit.install()
    assert kit.sleeps == [0.5] and installation.workspace_id == GUILD_ID


def test_two_rate_limits_wait_once_and_give_up(kit):
    kit.fake.rate_limits = 2
    with pytest.raises(DiscordSetupError):
        kit.install()
    assert kit.sleeps == [0.5]


def test_single_visible_server_is_used_when_no_workspace_is_given(kit):
    installation = kit.install(workspace="")
    assert (installation.workspace_id, installation.id) == (GUILD_ID, f"discord-{GUILD_ID}-{BOT}")


def test_no_saved_token_makes_no_request(kit):
    kit.token = None
    with pytest.raises(DiscordSetupError):
        kit.install()
    assert kit.fake.requests == []


def test_error_state_is_retryable_after_the_cause_is_fixed(kit):
    kit.allow_owner()
    kit.fake.reject_auth = True
    service = kit.service()
    failed, _ = service.begin(BOT, "discord", GUILD_ID)
    kit.fake.reject_auth = False
    recovered, installation = service.advance(BOT, "discord", GUILD_ID, wire.SetupEventKind.retry, failed.revision)
    assert (failed.step, recovered.step) == (wire.SetupStep.error, wire.SetupStep.ready)
    assert installation.id == f"discord-{GUILD_ID}-{BOT}"
