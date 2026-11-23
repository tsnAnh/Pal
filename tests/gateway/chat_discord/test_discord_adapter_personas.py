from __future__ import annotations

import logging
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock

import discord
import pytest

from gateway.chat_discord.runtime import DiscordBots
from gateway.config import PlatformConfig
from gateway.profile_routing import match_profile_route, parse_profile_routes
from plugins.platforms.discord.adapter import DiscordAdapter
from plugins.platforms.discord.webhook_send import WebhookClient
from tests.gateway.chat_discord.discord_kit import BOT, Kit
from tests.gateway.chat_discord.fake_discord import OWNER_ID
from tests.gateway.chat_discord.fake_webhook import FakeWebhookApi, error

OTHER_CHANNEL = "700000000000000001"
THREAD = "700000000000000002"
DM_CHANNEL = "800000000000000001"
STRANGER_ID = "999999999999999999"
BOT_USER_ID = 999


class RealChannel:
    def __init__(self, channel_id: str, parent_id: str | None = None):
        self.id = int(channel_id)
        self.parent_id = int(parent_id) if parent_id else None
        self.name = "pal-helper"
        self.topic = None
        self.guild = SimpleNamespace(name="Server", filesize_limit=25 * 1024 * 1024)
        self.sent: list[tuple] = []
        self.history = lambda **_: self._empty()

    @staticmethod
    async def _empty():
        return
        yield

    async def send(self, content=None, **kwargs):
        self.sent.append((content, kwargs))
        return SimpleNamespace(id=9_000 + len(self.sent), attachments=[])


class RealThread(RealChannel, discord.Thread):
    def __init__(self, channel_id: str, parent: RealChannel):
        super().__init__(channel_id, parent_id=str(parent.id))
        self.parent = parent


class FakeFile:
    def __init__(self, path, filename=None):
        self.fp = open(path, "rb")
        self.filename = filename

    def reset(self, seek=True):
        self.fp.seek(0)


class World:
    def __init__(self, kit: Kit, monkeypatch):
        for var in ("DISCORD_REQUIRE_MENTION", "DISCORD_FREE_RESPONSE_CHANNELS", "DISCORD_ALLOW_BOTS",
                    "DISCORD_AUTO_THREAD", "DISCORD_ALLOWED_CHANNELS", "DISCORD_IGNORED_CHANNELS"):
            monkeypatch.delenv(var, raising=False)
        monkeypatch.setenv("DISCORD_ALLOWED_USERS", OWNER_ID)
        self.kit, self.monkeypatch = kit, monkeypatch
        kit.allow_owner()
        self.installation = kit.install()
        self.channel_id = kit.home_channel()
        self.record = kit.record()
        self.repairs: list[str] = []
        self.api = FakeWebhookApi()
        self.channels = {self.channel_id: RealChannel(self.channel_id), OTHER_CHANNEL: RealChannel(OTHER_CHANNEL)}
        self.channels[THREAD] = RealThread(THREAD, self.channels[self.channel_id])
        self.names = {BOT: "Pal Helper", "default": "Pal"}
        self.runner = SimpleNamespace(
            config=SimpleNamespace(profile_routes=parse_profile_routes(kit.routes())),
            _profile_name_for_source=self.profile_for)
        adapter = DiscordAdapter(PlatformConfig(enabled=True, token="fake-token"))
        adapter._client = SimpleNamespace(
            user=SimpleNamespace(id=BOT_USER_ID, bot=True), get_channel=lambda cid: self.channels.get(str(cid)),
            fetch_channel=AsyncMock())

        async def no_sleep(_seconds):
            return None

        adapter._discord_bots = DiscordBots(
            records=kit.provider.records, vault=kit.vault, routes=kit.provider.routes,
            repair=lambda bot, _home: self.repairs.append(bot), display_name=lambda bot: self.names.get(bot, bot))
        adapter._discord_webhook_client = WebhookClient(self.api.transport, sleep=no_sleep)
        adapter._text_batch_delay_seconds = 0
        adapter.handle_message = AsyncMock()
        adapter.gateway_runner = self.runner
        self.adapter = adapter
        self.reload_gates()

    def reload_gates(self) -> None:
        self.adapter._derive_connect_gates()

    def profile_for(self, source, adapter_profile=None):
        route = match_profile_route(
            self.runner.config.profile_routes, source.platform.value, guild_id=getattr(source, "guild_id", None),
            chat_id=source.chat_id, thread_id=source.thread_id, parent_chat_id=source.parent_chat_id,
            user_id=source.user_id)
        return route.profile if route else None

    def secret_url(self) -> str:
        return self.kit.webhook_secret(self.installation)


@pytest.fixture
def world(kit, monkeypatch):
    return World(kit, monkeypatch)


@pytest.fixture
def avatar_world(avatar_kit, monkeypatch):
    return World(avatar_kit, monkeypatch)


def guild_message(channel, *, author_id: int = int(OWNER_ID), content: str = "hello", webhook_id=None,
                  mentions=None, bot: bool = False, guild=True):
    return SimpleNamespace(
        id=123, content=content, mentions=list(mentions or []), attachments=[], reference=None,
        created_at=datetime.now(UTC), channel=channel, guild=SimpleNamespace(id=1, name="Server") if guild else None,
        author=SimpleNamespace(id=author_id, display_name="Owner", name="owner", bot=bot), webhook_id=webhook_id,
        type=discord.MessageType.default)


@pytest.mark.asyncio
async def test_a_reply_in_the_bot_channel_posts_as_the_bot_through_its_webhook(world):
    result = await world.adapter.send(world.channel_id, "hello from the bot")

    assert result.success
    request = world.api.requests[0]
    assert request.url.path.startswith(f"/api/v10/webhooks/{world.record['webhook_id']}/")
    assert world.api.json_body()["content"] == "hello from the bot"
    assert world.api.json_body()["username"] == "Pal Helper"
    assert world.channels[world.channel_id].sent == []


@pytest.mark.asyncio
async def test_the_stored_avatar_travels_with_each_post(avatar_world):
    await avatar_world.adapter.send(avatar_world.channel_id, "hi")

    assert avatar_world.api.json_body()["avatar_url"] == avatar_world.record["webhook_avatar_url"]
    assert avatar_world.record["webhook_avatar_url"].endswith(".png")


@pytest.mark.asyncio
async def test_a_reply_in_a_thread_of_the_bot_channel_posts_with_the_thread_id(world):
    await world.adapter.send(THREAD, "thread reply")

    assert dict(world.api.requests[0].url.params)["thread_id"] == THREAD
    assert world.api.requests[0].url.path.startswith(f"/api/v10/webhooks/{world.record['webhook_id']}/")


@pytest.mark.asyncio
async def test_a_long_reply_is_split_at_2000_characters(world):
    await world.adapter.send(world.channel_id, "word " * 700)

    posts = [world.api.json_body(i)["content"] for i in range(len(world.api.requests))]
    assert len(posts) >= 2 and all(len(text) <= 2000 for text in posts)


@pytest.mark.asyncio
async def test_a_reply_outside_the_bot_channels_stays_the_pal_apps(world):
    await world.adapter.send(OTHER_CHANNEL, "mentioned elsewhere")

    assert world.api.requests == []
    assert world.channels[OTHER_CHANNEL].sent[0][0] == "mentioned elsewhere"


@pytest.mark.asyncio
async def test_an_edit_goes_through_the_webhook(world):
    result = await world.adapter.edit_message(world.channel_id, "123456", "final text", finalize=True)

    assert result.success
    assert world.api.requests[0].method == "PATCH"
    assert world.api.requests[0].url.path.endswith("/messages/123456")
    assert world.api.json_body()["content"] == "final text"


@pytest.mark.asyncio
async def test_a_file_upload_goes_through_the_webhook(world, tmp_path):
    world.monkeypatch.setattr(discord, "File", FakeFile)
    report = tmp_path / "report.txt"
    report.write_text("quarterly numbers")

    result = await world.adapter._send_file_attachment(world.channel_id, str(report), caption="here it is")

    assert result.success
    assert b"quarterly numbers" in world.api.requests[0].content
    assert world.channels[world.channel_id].sent == []


@pytest.mark.asyncio
async def test_a_deleted_webhook_delivers_through_the_pal_app_and_flags_the_install_for_repair(world):
    world.api.script = [error(404, 10015), error(404, 10015)]

    first = await world.adapter.send(world.channel_id, "still delivered")
    second = await world.adapter.send(world.channel_id, "delivered again")

    assert first.success and second.success
    assert [sent[0] for sent in world.channels[world.channel_id].sent] == ["still delivered", "delivered again"]
    assert world.repairs == [BOT]


@pytest.mark.asyncio
async def test_a_missing_vault_secret_repairs_instead_of_losing_the_reply(world):
    world.kit.vault.remove_item(world.installation.vault_item_ids[0])

    result = await world.adapter.send(world.channel_id, "delivered anyway")

    assert result.success and world.api.requests == []
    assert world.channels[world.channel_id].sent[0][0] == "delivered anyway"
    assert world.repairs == [BOT]


@pytest.mark.asyncio
async def test_the_webhook_secret_never_reaches_a_log_record(world, caplog):
    caplog.set_level(logging.DEBUG)
    world.api.script = [error(404, 10015)]

    await world.adapter.send(world.channel_id, "one")
    await world.adapter.send(world.channel_id, "two")

    assert world.secret_url().rsplit("/", 1)[1] not in caplog.text


@pytest.mark.parametrize("allow_bots", ["none", "mentions", "all"])
def test_messages_from_its_own_webhook_never_loop_back(world, allow_bots):
    world.monkeypatch.setenv("DISCORD_ALLOW_BOTS", allow_bots)
    world.reload_gates()
    me = world.adapter._client.user
    own = guild_message(world.channels[world.channel_id], webhook_id=int(world.record["webhook_id"]), bot=True,
                        content=f"<@{me.id}> hi", mentions=[me])

    assert world.adapter._discord_message_admission(own, claim=False) == (False, False)


def test_a_foreign_webhook_keeps_the_existing_bot_rules(world):
    world.monkeypatch.setenv("DISCORD_ALLOW_BOTS", "all")
    world.reload_gates()
    me = world.adapter._client.user
    foreign = guild_message(world.channels[world.channel_id], webhook_id=424242, bot=True,
                            content=f"<@{me.id}> hi", mentions=[me])

    admitted, _ = world.adapter._discord_message_admission(foreign, claim=False)

    assert admitted is True


def test_the_owner_is_admitted_in_the_bot_channel_and_a_stranger_is_not(world):
    channel = world.channels[world.channel_id]

    assert world.adapter._discord_message_admission(guild_message(channel), claim=False)[0] is True
    stranger = guild_message(channel, author_id=int(STRANGER_ID))
    assert world.adapter._discord_message_admission(stranger, claim=False) == (False, False)


@pytest.mark.asyncio
async def test_the_owner_needs_no_mention_in_the_bot_channel_and_the_message_routes_to_the_bot(world):
    await world.adapter._handle_message(guild_message(world.channels[world.channel_id]))

    world.adapter.handle_message.assert_awaited_once()
    event = world.adapter.handle_message.await_args.args[0]
    assert event.source.chat_id == world.channel_id and event.source.chat_type == "group"
    assert event.source.profile == BOT


@pytest.mark.asyncio
async def test_a_thread_under_the_bot_channel_needs_no_mention_either(world):
    await world.adapter._handle_message(guild_message(world.channels[THREAD]))

    event = world.adapter.handle_message.await_args.args[0]
    assert event.source.profile == BOT


@pytest.mark.asyncio
async def test_an_ordinary_channel_still_needs_a_mention(world):
    await world.adapter._handle_message(guild_message(world.channels[OTHER_CHANNEL]))

    world.adapter.handle_message.assert_not_awaited()


@pytest.mark.asyncio
async def test_a_mention_in_an_ordinary_channel_goes_to_the_default_bot_and_is_answered_as_the_pal_app(world):
    world.monkeypatch.setenv("DISCORD_AUTO_THREAD", "false")
    me = world.adapter._client.user
    message = guild_message(world.channels[OTHER_CHANNEL], content=f"<@{me.id}> hi", mentions=[me])

    await world.adapter._handle_message(message)

    event = world.adapter.handle_message.await_args.args[0]
    assert event.source.profile is None
    await world.adapter.send(event.source.chat_id, "plain reply")
    assert world.api.requests == [] and world.channels[OTHER_CHANNEL].sent[0][0] == "plain reply"


def test_free_response_never_widens_beyond_the_pal_created_channels(world):
    free = world.adapter._discord_free_response_channels()

    assert free == {world.channel_id}
    world.kit.provider.revoke(world.installation)
    assert world.adapter._discord_free_response_channels() == set()


@pytest.mark.asyncio
async def test_webhook_posts_never_allow_everyone_or_role_pings(world):
    await world.adapter.send(world.channel_id, "@everyone @here <@&123> <@42>")

    mentions = world.api.json_body()["allowed_mentions"]
    assert mentions == {"parse": ["users"]}


def dm_message():
    dm_channel = object.__new__(discord.DMChannel)
    dm_channel.id = int(DM_CHANNEL)
    return guild_message(dm_channel, content="hi from my phone", guild=False)


def dm_interaction(user_id: str = OWNER_ID, channel_id: str = DM_CHANNEL):
    dm_channel = object.__new__(discord.DMChannel)
    return SimpleNamespace(
        user=SimpleNamespace(id=int(user_id), name="owner"), channel=dm_channel, channel_id=int(channel_id),
        guild_id=None, guild=None, response=SimpleNamespace(send_message=AsyncMock()))


class FakeCommand:
    def __init__(self, *, name, description, callback, parent=None):
        self.name, self.description, self.callback = name, description, callback

    def to_dict(self, _tree):
        return {"name": self.name, "description": self.description, "type": 1}


class FakeTree:
    def __init__(self):
        self.commands: dict[str, FakeCommand] = {}

    def add_command(self, command):
        self.commands[command.name] = command

    def get_command(self, name):
        return self.commands.get(name)

    def get_commands(self):
        return list(self.commands.values())


@pytest.fixture
def tree(world):
    def autocomplete(**callbacks):
        def decorate(fn):
            fn.autocompletes = callbacks
            return fn
        return decorate

    world.monkeypatch.setattr(discord.app_commands, "autocomplete", autocomplete, raising=False)
    world.monkeypatch.setattr(discord.app_commands, "Command", FakeCommand, raising=False)
    tree = FakeTree()
    world.adapter._client.tree = tree
    return tree


def pal_command(tree):
    return tree.get_command("pal")


def said(interaction) -> str:
    return interaction.response.send_message.await_args.args[0]


def test_pal_is_registered_once_and_the_command_sync_stays_stable(world, tree):
    world.adapter._register_pal_command(tree)
    first = world.adapter._desired_command_sync_fingerprint()
    world.adapter._register_pal_command(tree)

    assert [command.name for command in tree.get_commands()].count("pal") == 1
    assert world.adapter._desired_command_sync_fingerprint() == first


def test_pal_is_not_registered_when_no_bot_is_installed(world, tree):
    world.kit.provider.revoke(world.installation)

    world.adapter._register_pal_command(tree)

    assert pal_command(tree) is None


@pytest.mark.asyncio
async def test_pal_autocomplete_lists_only_installed_bots_for_the_owner(world, tree):
    world.adapter._register_pal_command(tree)
    autocomplete = pal_command(tree).callback.autocompletes["bot"]

    choices = await autocomplete(dm_interaction(), "")
    filtered = await autocomplete(dm_interaction(), "zzz")
    refused = await autocomplete(dm_interaction(user_id=STRANGER_ID), "")

    assert [(choice.name, choice.value) for choice in choices] == [("Pal Helper", BOT)]
    assert filtered == [] and refused == []


@pytest.mark.asyncio
async def test_pal_switches_the_dm_to_the_chosen_bot_and_the_next_dm_resolves_to_it(world, tree):
    world.adapter._register_pal_command(tree)
    interaction = dm_interaction()

    await pal_command(tree).callback(interaction, bot=BOT)

    assert said(interaction) == "Now talking to Pal Helper."
    assert interaction.response.send_message.await_args.kwargs == {"ephemeral": True}
    assert {"name": f"pal-discord-dm-{DM_CHANNEL}", "platform": "discord", "chat_id": DM_CHANNEL,
            "profile": BOT} in world.kit.routes()
    matched = match_profile_route(world.runner.config.profile_routes, "discord", chat_id=DM_CHANNEL, user_id=OWNER_ID)
    assert matched is not None and matched.profile == BOT
    await world.adapter._handle_message(dm_message())
    assert world.adapter.handle_message.await_args.args[0].source.profile == BOT


@pytest.mark.asyncio
async def test_pal_without_an_option_names_the_current_bot_and_the_choices(world, tree):
    world.adapter._register_pal_command(tree)
    interaction = dm_interaction()

    await pal_command(tree).callback(interaction)

    assert "You're talking to Pal." in said(interaction) and "Pal Helper" in said(interaction)
    await pal_command(tree).callback(dm_interaction(), bot=BOT)
    after = dm_interaction()
    await pal_command(tree).callback(after)
    assert "You're talking to Pal Helper." in said(after)


@pytest.mark.asyncio
async def test_pal_can_return_a_dm_to_the_default_bot(world, tree):
    world.adapter._register_pal_command(tree)
    await world.adapter._handle_message(dm_message())
    assert world.adapter.handle_message.await_args.args[0].source.profile is None
    await pal_command(tree).callback(dm_interaction(), bot=BOT)
    interaction = dm_interaction()

    await pal_command(tree).callback(interaction, bot="default")

    assert said(interaction) == "Now talking to Pal."
    await world.adapter._handle_message(dm_message())
    assert world.adapter.handle_message.await_args.args[0].source.profile is None
    assert not [route for route in world.kit.routes() if route["name"].startswith("pal-discord-dm-")]
    assert world.runner.config.profile_routes == [route for route in world.runner.config.profile_routes
                                                  if route.chat_id != DM_CHANNEL]


@pytest.mark.asyncio
async def test_pal_refuses_an_unknown_bot_without_changing_anything(world, tree):
    world.adapter._register_pal_command(tree)
    interaction = dm_interaction()

    await pal_command(tree).callback(interaction, bot="nobody")

    assert "I don't know that bot" in said(interaction)
    assert not [route for route in world.kit.routes() if route["name"].startswith("pal-discord-dm-")]


@pytest.mark.asyncio
async def test_pal_refuses_anyone_but_the_owner_without_leaking_bot_names(world, tree):
    world.adapter._register_pal_command(tree)
    stranger = dm_interaction(user_id=STRANGER_ID)

    await pal_command(tree).callback(stranger, bot=BOT)

    assert "Pal Helper" not in said(stranger)
    assert not [route for route in world.kit.routes() if route["name"].startswith("pal-discord-dm-")]


@pytest.mark.asyncio
async def test_pal_only_switches_in_a_direct_message(world, tree):
    world.adapter._register_pal_command(tree)
    interaction = dm_interaction()
    interaction.guild_id = 1
    interaction.channel = world.channels[OTHER_CHANNEL]

    await pal_command(tree).callback(interaction, bot=BOT)

    assert said(interaction) == "Use /pal in a direct message with me."
    assert not [route for route in world.kit.routes() if route["name"].startswith("pal-discord-dm-")]


@pytest.mark.asyncio
async def test_pal_refuses_an_allowed_user_who_is_not_the_owner(world, tree):
    world.monkeypatch.setenv("DISCORD_ALLOWED_USERS", f"{OWNER_ID},{STRANGER_ID}")
    world.reload_gates()
    world.adapter._register_pal_command(tree)
    guest = dm_interaction(user_id=STRANGER_ID)

    await pal_command(tree).callback(guest, bot=BOT)

    assert said(guest) == "Only the owner can use /pal." and "Pal Helper" not in said(guest)
    assert await pal_command(tree).callback.autocompletes["bot"](dm_interaction(user_id=STRANGER_ID), "") == []
    assert not [route for route in world.kit.routes() if route["name"].startswith("pal-discord-dm-")]


@pytest.mark.asyncio
async def test_revoking_a_bot_drops_the_dm_routes_that_point_at_it(world, tree):
    world.adapter._register_pal_command(tree)
    await pal_command(tree).callback(dm_interaction(), bot=BOT)

    world.kit.provider.revoke(world.installation)

    assert not [route for route in world.kit.routes() if route["profile"] == BOT]


@pytest.mark.asyncio
async def test_a_failing_repair_request_never_costs_the_reply(world):
    world.adapter._discord_bots.flag_repair = lambda bot: 1 / 0
    world.api.script = [error(404, 10015)]

    result = await world.adapter.send(world.channel_id, "still delivered")

    assert result.success
    assert world.channels[world.channel_id].sent[0][0] == "still delivered"
