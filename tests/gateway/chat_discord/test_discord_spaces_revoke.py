from __future__ import annotations

import pytest

from gateway.chat_discord.api import DiscordSetupError
from tests.gateway.chat_discord.discord_kit import BOT, route_for
from tests.gateway.chat_discord.fake_discord import GUILD_ID, OWNER_ID
from tui_gateway.contracts import chat_provider as wire

JOIN = wire.SpaceJoinOutcome
LEAVE = wire.SpaceLeaveOutcome
ENV_KEY = "DISCORD_ALLOWED_USERS"
UNSEEN_CHANNEL = "999999999999999999"


@pytest.fixture
def installed(kit):
    installation = kit.install()
    general = kit.fake.add_channel("general")
    kit.fake.add_channel("voice-room", kind=2)
    return kit, installation, general


def env_text(kit) -> str:
    path = kit.home / ".env"
    return path.read_text(encoding="utf-8") if path.exists() else ""


def test_ensure_writes_the_owner_into_the_env_file(kit):
    assert kit.provider.allowlist.ensure(OWNER_ID) is True
    assert f"{ENV_KEY}={OWNER_ID}" in env_text(kit)


def test_ensure_does_not_duplicate_an_existing_owner(kit):
    kit.provider.allowlist.ensure(OWNER_ID)
    assert kit.provider.allowlist.ensure(OWNER_ID) is False
    assert env_text(kit).count(OWNER_ID) == 1


def test_ensure_keeps_existing_ids_in_order(kit):
    kit.provider.allowlist.ensure("111111111111111111")
    kit.provider.allowlist.ensure(OWNER_ID)
    assert kit.provider.allowlist.users() == ["111111111111111111", OWNER_ID]


def test_apply_owner_leaves_an_online_adapter_alone_when_nothing_changed(kit):
    installation = kit.install()
    kit.provider.apply_owner(installation, OWNER_ID)
    kit.provider.apply_owner(installation, OWNER_ID)
    assert kit.runtime.reloads == 1


def test_apply_owner_never_restarts_the_gateway(kit):
    kit.provider.apply_owner(kit.install(), OWNER_ID)
    assert kit.restarts == []


@pytest.mark.parametrize("raw", ["123456789012345678", " 123456789012345678 ", "<@123456789012345678>",
                                 "<@!123456789012345678>"])
def test_owner_identity_accepts_ids_and_mentions(kit, raw):
    assert kit.provider.parse_owner_identity(raw) == "123456789012345678"


@pytest.mark.parametrize("raw", ["abc", "", "   ", "<@abc>", "12 34", "@owner"])
def test_owner_identity_rejects_everything_else(kit, raw):
    assert kit.provider.parse_owner_identity(raw) is None


def test_authorizing_identity_is_the_allowlisted_owner(kit):
    kit.allow_owner()
    assert kit.provider.authorizing_identity(kit.install()) == OWNER_ID


def test_list_spaces_returns_only_text_channels(installed):
    kit, installation, _ = installed
    assert sorted(space.name for space in kit.provider.list_spaces(installation)) == ["general", "pal-helper"]


def test_list_spaces_marks_only_the_bots_channel_joined(installed):
    kit, installation, _ = installed
    joined = {space.name: space.joined for space in kit.provider.list_spaces(installation)}
    assert joined == {"general": False, "pal-helper": True}


def test_join_space_routes_the_channel_and_records_it_as_an_extra(installed):
    kit, installation, general = installed
    result = kit.provider.join_space(installation, general)
    assert result.outcome is JOIN.joined
    assert kit.routes() == [route_for(BOT, kit.home_channel()), route_for(BOT, general)]
    assert kit.record()["extra_channel_ids"] == [general]


def test_joined_extra_shows_as_joined_in_the_listing(installed):
    kit, installation, general = installed
    kit.provider.join_space(installation, general)
    assert {s.name: s.joined for s in kit.provider.list_spaces(installation)}["general"] is True


def test_joining_twice_reports_already_joined_and_changes_nothing(installed):
    kit, installation, general = installed
    kit.provider.join_space(installation, general)
    reloads = len(kit.route_reloads)
    assert kit.provider.join_space(installation, general).outcome is JOIN.already_joined
    assert len(kit.routes()) == 2 and len(kit.route_reloads) == reloads


def test_joining_the_home_channel_is_already_joined(installed):
    kit, installation, _ = installed
    assert kit.provider.join_space(installation, kit.home_channel()).outcome is JOIN.already_joined


def test_invisible_channel_needs_an_invite_and_gets_no_route(installed):
    kit, installation, _ = installed
    result = kit.provider.join_space(installation, UNSEEN_CHANNEL)
    assert result.outcome is JOIN.needs_invite and kit.routes() == [route_for(BOT, kit.home_channel())]


def test_joining_a_channel_routed_to_another_profile_is_a_conflict(installed):
    kit, installation, general = installed
    kit.set_routes([*kit.routes(), route_for("other", general)])
    with pytest.raises(DiscordSetupError) as raised:
        kit.provider.join_space(installation, general)
    assert (raised.value.code, raised.value.reason) == (wire.SetupErrorCode.install_failed, "route_conflict")
    assert kit.record()["extra_channel_ids"] == []


def test_reinstall_keeps_the_joined_extra_route(installed):
    kit, installation, general = installed
    kit.provider.join_space(installation, general)
    kit.install()
    assert {r["chat_id"] for r in kit.routes()} == {kit.home_channel(), general}


def test_leaving_an_extra_removes_its_route_and_record(installed):
    kit, installation, general = installed
    kit.provider.join_space(installation, general)
    assert kit.provider.leave_space(installation, general) is LEAVE.left
    assert kit.routes() == [route_for(BOT, kit.home_channel())] and kit.record()["extra_channel_ids"] == []


def test_leaving_the_home_channel_is_not_a_membership(installed):
    kit, installation, _ = installed
    assert kit.provider.leave_space(installation, kit.home_channel()) is LEAVE.not_member
    assert kit.routes() == [route_for(BOT, kit.home_channel())]


def test_leaving_an_unknown_channel_is_not_a_membership(installed):
    kit, installation, _ = installed
    assert kit.provider.leave_space(installation, UNSEEN_CHANNEL) is LEAVE.not_member


def joined_install(installed):
    kit, installation, general = installed
    kit.provider.join_space(installation, general)
    return kit, installation, general


def test_revoke_deletes_the_discord_webhook(installed):
    kit, installation, _ = joined_install(installed)
    kit.provider.revoke(installation)
    assert kit.fake.webhooks == {}


def test_revoke_removes_every_route_and_the_vault_item(installed):
    kit, installation, _ = joined_install(installed)
    kit.provider.revoke(installation)
    assert (kit.routes(), kit.vault.list_items()) == ([], [])


def test_revoke_keeps_the_channel_and_its_record(installed):
    kit, installation, _ = joined_install(installed)
    channel = kit.home_channel()
    kit.provider.revoke(installation)
    assert channel in {c["id"] for c in kit.fake.text_channels()} and kit.record()["channel_id"] == channel
    assert (kit.record()["webhook_id"], kit.record()["extra_channel_ids"]) == ("", [])


def test_second_revoke_is_a_no_op(installed):
    kit, installation, _ = joined_install(installed)
    kit.provider.revoke(installation)
    calls, reloads = len(kit.fake.requests), len(kit.route_reloads)
    kit.provider.revoke(installation)
    assert (len(kit.fake.requests), len(kit.route_reloads)) == (calls, reloads)


def test_revoke_tolerates_a_webhook_already_gone(installed):
    kit, installation, _ = installed
    kit.fake.delete_webhook_remote(kit.record()["webhook_id"])
    kit.provider.revoke(installation)
    assert (kit.routes(), kit.vault.list_items()) == ([], [])


def test_revoke_without_a_saved_token_still_cleans_up_locally(installed):
    kit, installation, _ = installed
    kit.token = None
    kit.provider.revoke(installation)
    assert (kit.routes(), kit.vault.list_items()) == ([], [])


def test_revoke_reraises_when_discord_is_unreachable_and_changes_nothing(installed):
    kit, installation, _ = joined_install(installed)
    routes, record = kit.routes(), kit.record()
    kit.fake.network_down = True
    with pytest.raises(DiscordSetupError) as raised:
        kit.provider.revoke(installation)
    assert raised.value.code is wire.SetupErrorCode.provider_unreachable
    assert (kit.routes(), kit.record(), len(kit.vault.list_items())) == (routes, record, 1)


def test_install_after_revoke_reuses_the_channel_and_makes_a_new_webhook(installed):
    kit, installation, _ = installed
    channel, old_item = kit.home_channel(), installation.vault_item_ids
    kit.provider.revoke(installation)
    again = kit.install()
    assert [c["id"] for c in kit.fake.text_channels() if c["name"] == "pal-helper"] == [channel]
    assert len(kit.fake.webhooks) == 1 and again.vault_item_ids != old_item
    assert kit.routes() == [route_for(BOT, channel)]
