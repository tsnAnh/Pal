from __future__ import annotations

import contextlib

import httpx
import pytest

from gateway.chat_discord.runtime import DiscordBots
from gateway.chat_install_service import ChatInstallService, ChatServiceError
from gateway.chat_install_store import ChatInstallStore
from tests.gateway.chat_discord.discord_kit import BOT, Kit, route_for
from tests.gateway.chat_discord.fake_discord import GUILD_ID, OWNER_ID
from tui_gateway import chat_install as ci
from tui_gateway import chat_providers
from tui_gateway.contracts import METHODS
from tui_gateway.contracts import chat_provider as wire

STEP = wire.SetupStep
EVENT = wire.SetupEventKind
APP_OWNER = "223456789012345678"
TEAM_OWNER = "323456789012345678"
TEAM_USER = "423456789012345678"
USER_APP = {"owner": {"id": APP_OWNER, "username": "maker"}}
TEAM_APP = {"owner": {"id": TEAM_USER, "username": "team1"}, "team": {"id": "1", "owner_user_id": TEAM_OWNER}}


def pal_command_owners(kit: Kit) -> frozenset[str]:
    return DiscordBots(records=kit.provider.records).owner_ids()


def begin(kit: Kit):
    return kit.service().begin(BOT, "discord", GUILD_ID)


def ready(kit: Kit):
    kit.allow_owner()
    service = kit.service()
    service.begin(BOT, "discord", GUILD_ID)
    return service


def test_begin_reaches_ready_when_the_owner_is_already_allowlisted(kit):
    kit.allow_owner()
    state, installation = begin(kit)
    assert state.step is STEP.ready and installation.id == f"discord-{GUILD_ID}-{BOT}"


def test_begin_needs_no_public_url(kit):
    kit.allow_owner()
    assert begin(kit)[0].step is STEP.ready


def test_install_never_touches_adapter_env_or_restarts_the_gateway(kit):
    kit.allow_owner()
    begin(kit)
    assert (kit.control.applied, kit.control.reloads, kit.restarts) == ([], [], [])


def test_status_exposes_the_installation_once_ready(kit):
    service = ready(kit)
    state, installation = service.status(BOT, "discord", GUILD_ID)
    assert (state.step, installation.workspace_id) == (STEP.ready, GUILD_ID)


def test_ready_install_has_its_route_and_one_webhook(kit):
    ready(kit)
    assert kit.routes() == [route_for(BOT, kit.home_channel())] and len(kit.fake.webhooks) == 1


def test_without_an_owner_the_install_waits_for_one(kit):
    state, _ = begin(kit)
    assert state.step is STEP.needs_owner and state.next_action.action_id == "owner_member_id"
    assert len(kit.fake.webhooks) == 1


def test_confirming_the_owner_reaches_ready(kit):
    service = kit.service()
    waiting, _ = service.begin(BOT, "discord", GUILD_ID)
    state, installation = service.advance(BOT, "discord", GUILD_ID, EVENT.owner_confirmed, waiting.revision,
                                          owner_member_id=OWNER_ID)
    assert state.step is STEP.ready and installation is not None


def test_confirming_the_owner_puts_them_on_the_allowlist(kit):
    service = kit.service()
    waiting, _ = service.begin(BOT, "discord", GUILD_ID)
    service.advance(BOT, "discord", GUILD_ID, EVENT.owner_confirmed, waiting.revision, owner_member_id=f"<@{OWNER_ID}>")
    assert kit.provider.allowlist.users() == [OWNER_ID]
    assert [keys for _, _, keys in kit.platform_reloads] == [["DISCORD_ALLOWED_USERS"]]


def test_a_malformed_owner_keeps_waiting(kit):
    service = kit.service()
    waiting, _ = service.begin(BOT, "discord", GUILD_ID)
    with pytest.raises(ChatServiceError):
        service.advance(BOT, "discord", GUILD_ID, EVENT.owner_confirmed, waiting.revision, owner_member_id="abc")
    assert service.status(BOT, "discord", GUILD_ID)[0].step is STEP.needs_owner


@pytest.mark.parametrize(("application", "owner"), [(USER_APP, APP_OWNER), (TEAM_APP, TEAM_OWNER)])
def test_install_finishes_with_the_discord_application_owner(kit, application, owner):
    kit.fake.application_extra = application
    state, installation = begin(kit)
    assert state.step is STEP.ready
    assert ChatInstallStore(kit.home).owner_id(installation.id) == owner
    assert kit.provider.allowlist.users() == [owner] and pal_command_owners(kit) == {owner}


@pytest.mark.parametrize("application", [
    {}, {"owner": None}, {"owner": {}}, {"owner": {"id": "not-a-snowflake"}}, {"owner": {"id": 223456789012345678}},
    {"owner": {"id": TEAM_USER}, "team": {"id": "1"}}, {"owner": {"id": TEAM_USER}, "team": {"owner_user_id": None}},
])
def test_install_asks_for_the_owner_when_discord_names_none(kit, application):
    kit.fake.application_extra = application
    assert begin(kit)[0].step is STEP.needs_owner
    assert kit.provider.allowlist.users() == []


@pytest.mark.parametrize("response", [
    httpx.Response(500, json={}), httpx.Response(200, content=b""), httpx.Response(200, json=[]),
    httpx.Response(404, json={"code": 10003}), httpx.Response(401, json={"code": 0}),
])
def test_a_failed_owner_lookup_asks_for_the_owner_instead_of_failing(kit, response):
    kit.fake.application_extra = USER_APP
    kit.fake.later_application_response = response
    state, _ = begin(kit)
    assert state.step is STEP.needs_owner and state.error is None


def test_an_allowlisted_owner_wins_over_the_application_owner(kit):
    kit.fake.application_extra = USER_APP
    kit.allow_owner()
    assert begin(kit)[0].step is STEP.ready
    assert kit.provider.allowlist.users() == [OWNER_ID]


def test_a_waiting_setup_finishes_on_the_next_begin_once_discord_names_the_owner(kit):
    assert begin(kit)[0].step is STEP.needs_owner
    kit.fake.application_extra = USER_APP
    state, installation = begin(kit)
    assert state.step is STEP.ready and installation is not None
    assert kit.provider.allowlist.users() == [APP_OWNER]


def test_a_waiting_setup_keeps_waiting_while_discord_names_no_owner(kit):
    waiting, _ = begin(kit)
    again, _ = begin(kit)
    assert (again.step, again.revision) == (STEP.needs_owner, waiting.revision)


def test_a_typed_owner_may_use_the_pal_command(kit):
    service = kit.service()
    waiting, _ = service.begin(BOT, "discord", GUILD_ID)
    service.advance(BOT, "discord", GUILD_ID, EVENT.owner_confirmed, waiting.revision, owner_member_id=OWNER_ID)
    assert pal_command_owners(kit) == {OWNER_ID}


def test_revoke_through_the_service_reaches_revoked_and_keeps_the_channel(kit):
    service = ready(kit)
    channel = kit.home_channel()
    state, installation = service.revoke(BOT, "discord", GUILD_ID)
    assert (state.step, installation) == (STEP.revoked, None)
    assert [c["id"] for c in kit.fake.text_channels()] == [channel] and kit.fake.webhooks == {}


def test_revoke_through_the_service_clears_routes_and_vault(kit):
    service = ready(kit)
    service.revoke(BOT, "discord", GUILD_ID)
    assert (kit.routes(), kit.vault.list_items(), kit.control.applied) == ([], [], [])


def test_install_again_after_revoke_reuses_the_channel(kit):
    service = ready(kit)
    channel = kit.home_channel()
    service.revoke(BOT, "discord", GUILD_ID)
    state, _ = service.begin(BOT, "discord", GUILD_ID)
    assert state.step is STEP.ready and [c["id"] for c in kit.fake.text_channels()] == [channel]


def test_revoke_while_discord_is_unreachable_fails_and_stays_ready(kit):
    service = ready(kit)
    kit.fake.network_down = True
    with pytest.raises(ChatServiceError):
        service.revoke(BOT, "discord", GUILD_ID)
    assert service.status(BOT, "discord", GUILD_ID)[0].step is STEP.ready and len(kit.routes()) == 1


def test_update_identity_through_the_service_heals_a_deleted_channel(kit):
    service = ready(kit)
    old = kit.home_channel()
    kit.fake.delete_channel(old)
    result = service.update_identity(BOT, "discord", GUILD_ID)
    assert result.outcome is wire.IdentityUpdateOutcome.updated
    assert [c["id"] for c in kit.fake.text_channels()] == [kit.home_channel()] != [old]
    assert kit.routes() == [route_for(BOT, kit.home_channel())] and len(kit.fake.webhooks) == 1


def test_update_identity_returns_the_projected_identity(kit):
    service = ready(kit)
    kit.names[BOT] = "Discord Pal"
    assert service.update_identity(BOT, "discord", GUILD_ID).identity.username == "Pal"


def test_joining_a_space_through_the_service_binds_it_live(kit):
    service = ready(kit)
    general = kit.fake.add_channel("general")
    service.join(BOT, "discord", GUILD_ID, general, hello=False)
    assert [(b.space_id, b.live) for b in service.bindings(BOT) if b.space_id == general] == [(general, True)]


def test_leaving_a_space_through_the_service_drops_the_binding(kit):
    service = ready(kit)
    general = kit.fake.add_channel("general")
    service.join(BOT, "discord", GUILD_ID, general, hello=False)
    assert service.leave(BOT, "discord", GUILD_ID, general) is wire.SpaceLeaveOutcome.left
    assert [b.space_id for b in service.bindings(BOT) if b.space_id == general] == []


def test_provider_list_includes_discord_from_the_real_registry(kit):
    service = ChatInstallService(
        store=ChatInstallStore(kit.home), provider_for=chat_providers.provider_for, control=kit.control,
        public_url=lambda: None, bot_scope=lambda _bot: contextlib.nullcontext())
    assert {c.provider_id: c for c in service.provider_capabilities()}["discord"] == ci.DISCORD_CAPABILITIES


def test_every_chat_contract_has_a_handler_and_every_handler_a_contract():
    from tui_gateway import server
    contracts = {name for name in METHODS if name.startswith("chat.")}
    handlers = {name for name in server._methods if name.startswith("chat.")}
    assert contracts and contracts == handlers


def test_setup_error_wire_model_round_trips_the_new_fields():
    payload = {"code": "install_failed", "fix": "retry", "reason": "missing_permission",
               "permissions": ["Manage Channels", "Manage Webhooks"], "retry_after_seconds": 3}
    error = wire.SetupError.model_validate(payload)
    assert error.model_dump(mode="json") == payload


def test_setup_error_defaults_are_empty():
    error = wire.SetupError.model_validate({"code": "credential_rejected", "fix": "reenter_credential"})
    assert (error.reason, error.permissions, error.retry_after_seconds) == (None, [], None)


def test_setup_error_rejects_a_negative_retry_after():
    with pytest.raises(ValueError):
        wire.SetupError.model_validate({"code": "provider_unreachable", "fix": "retry", "retry_after_seconds": -1})
