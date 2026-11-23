from __future__ import annotations

import pytest

from gateway.chat_discord.default_profile import RouteConflict
from gateway.chat_discord.runtime import DiscordBots
from tests.gateway.chat_discord.discord_kit import BOT, DISPLAY_NAME, Kit
from tests.gateway.chat_discord.fake_discord import AVATAR_HASH, GUILD_ID, OWNER_ID

DM_CHANNEL = "800000000000000001"
OTHER_HOME = {"platform": "discord", "chat_id": "123456", "name": "Elsewhere"}


class Clock:
    def __init__(self):
        self.now = 1_000.0

    def __call__(self) -> float:
        return self.now


def bots_for(kit: Kit, repairs: list[str], clock=None) -> DiscordBots:
    return DiscordBots(records=kit.provider.records, vault=kit.vault, routes=kit.provider.routes,
                       repair=lambda bot, _home: repairs.append(bot), display_name=lambda bot: kit.identity(bot).display_name,
                       **({"clock": clock} if clock else {}))


def test_install_stores_the_webhook_name_and_avatar_url_but_no_secret(avatar_kit):
    installation = avatar_kit.install()

    record = avatar_kit.record()
    assert record["webhook_name"] == DISPLAY_NAME
    assert record["webhook_avatar_url"] == f"https://cdn.discordapp.com/avatars/{record['webhook_id']}/{AVATAR_HASH}.png"
    assert avatar_kit.webhook_secret(installation) not in avatar_kit.records_text()


def test_a_forbidden_word_never_reaches_the_webhook_name(kit):
    kit.names[BOT] = "Discord Clyde Helper"

    kit.install()

    assert kit.record()["webhook_name"] == "Helper"


def test_the_heal_refreshes_the_stored_identity(avatar_kit):
    installation = avatar_kit.install()
    avatar_kit.names[BOT] = "Renamed Helper"

    avatar_kit.provider.update_identity(installation)

    assert avatar_kit.record()["webhook_name"] == "Renamed Helper"


def test_the_bot_channels_and_webhook_ids_follow_the_installs(kit):
    installation = kit.install()
    bots = bots_for(kit, [])

    assert bots.bot_channel_ids() == {kit.home_channel()}
    assert bots.webhook_ids() == {kit.record()["webhook_id"]}
    assert [(choice.name, choice.display_name) for choice in bots.installed_bots()] == [(BOT, DISPLAY_NAME)]

    kit.provider.revoke(installation)
    assert bots.bot_channel_ids() == frozenset() and bots.webhook_ids() == frozenset() and bots.installed_bots() == []


def test_the_endpoint_reads_the_secret_from_the_vault_only_for_the_bot_channel(kit):
    installation = kit.install()
    bots = bots_for(kit, [])

    endpoint = bots.endpoint_for(kit.home_channel())

    assert endpoint.url == kit.webhook_secret(installation)
    assert endpoint.bot == BOT and endpoint.username == DISPLAY_NAME
    assert kit.webhook_secret(installation) not in repr(endpoint)
    assert bots.endpoint_for("900000000000000009") is None


def test_a_vault_that_lost_the_secret_asks_for_one_repair_per_minute(kit):
    installation = kit.install()
    repairs: list[str] = []
    clock = Clock()
    bots = bots_for(kit, repairs, clock)
    kit.vault.remove_item(installation.vault_item_ids[0])

    assert bots.endpoint_for(kit.home_channel()) is None
    assert bots.endpoint_for(kit.home_channel()) is None
    assert repairs == [BOT]
    clock.now += 61
    assert bots.endpoint_for(kit.home_channel()) is None
    assert repairs == [BOT, BOT]


def test_direct_routes_are_set_cleared_and_idempotent(kit):
    kit.install()
    routes = kit.provider.routes

    assert routes.direct_bot(DM_CHANNEL) is None
    assert routes.set_direct(DM_CHANNEL, BOT) is True
    assert routes.set_direct(DM_CHANNEL, BOT) is False
    assert routes.direct_bot(DM_CHANNEL) == BOT
    assert routes.set_direct(DM_CHANNEL, "other") is True
    assert routes.direct_bot(DM_CHANNEL) == "other"
    assert len([r for r in kit.routes() if r["chat_id"] == DM_CHANNEL]) == 1
    assert routes.clear_direct(DM_CHANNEL) is True
    assert routes.clear_direct(DM_CHANNEL) is False
    assert routes.direct_bot(DM_CHANNEL) is None
    assert [r for r in kit.routes() if r["chat_id"] == kit.home_channel()]


def test_a_dm_route_never_replaces_a_route_someone_else_owns(kit):
    kit.set_routes([{"name": "mine", "platform": "discord", "chat_id": DM_CHANNEL, "profile": "work"}])

    with pytest.raises(RouteConflict):
        kit.provider.routes.set_direct(DM_CHANNEL, BOT)

    assert kit.routes() == [{"name": "mine", "platform": "discord", "chat_id": DM_CHANNEL, "profile": "work"}]


def test_finishing_an_install_seeds_the_bots_channel_as_its_home_channel(kit):
    kit.allow_owner()

    state, installation = kit.service().begin(BOT, "discord", GUILD_ID)

    home = kit.config()["platforms"]["discord"]["home_channel"]
    assert state.step.value == "ready"
    assert home["chat_id"] == kit.home_channel() and home["platform"] == "discord"
    assert home["user_id"] == OWNER_ID and home["scope_id"] == GUILD_ID and home["name"] == DISPLAY_NAME
    assert installation.provider_id == "discord"


def test_an_existing_home_channel_is_never_overridden(kit):
    kit.allow_owner()
    from hermes_cli.config import load_config, save_config
    config = load_config()
    config.setdefault("platforms", {}).setdefault("discord", {})["home_channel"] = dict(OTHER_HOME)
    save_config(config)

    kit.service().begin(BOT, "discord", GUILD_ID)

    assert kit.config()["platforms"]["discord"]["home_channel"] == OTHER_HOME


def test_a_second_install_check_keeps_the_seeded_home_channel(kit):
    kit.allow_owner()
    service = kit.service()
    service.begin(BOT, "discord", GUILD_ID)
    from hermes_cli.config import load_config, save_config
    config = load_config()
    config["platforms"]["discord"]["home_channel"] = dict(OTHER_HOME)
    save_config(config)

    service.begin(BOT, "discord", GUILD_ID)
    service.update_identity(BOT, "discord", GUILD_ID)

    assert kit.config()["platforms"]["discord"]["home_channel"] == OTHER_HOME
