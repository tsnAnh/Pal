from __future__ import annotations

import base64
import io
import logging

import pytest
from PIL import Image

from gateway.chat_discord.api import DiscordSetupError
from gateway.chat_discord.provider import DiscordProvider
from tests.gateway.chat_discord.discord_kit import BOT, DISPLAY_NAME, Kit, dumps, route_for
from tests.gateway.chat_discord.fake_discord import BOT_ID, GUILD_ID, TOKEN
from tui_gateway import chat_install as ci
from tui_gateway import chat_providers
from tui_gateway.contracts import chat_provider as wire

CAP = wire.ProviderCapability
MODE = wire.CapabilityMode
PNG_PREFIX = "data:image/png;base64,"


def modes(caps: wire.Capabilities) -> dict:
    return {entry.capability: entry.mode for entry in caps.capabilities}


def projection(kit: Kit, name: str, avatar: str | None = None) -> wire.IdentityProjection:
    return kit.provider.identity_projection(ci.BotIdentitySource(BOT, name, avatar))


def secret_urls(kit: Kit) -> list[str]:
    return [f"https://discord.com/api/webhooks/{w['id']}/{w['token']}" for w in kit.fake.webhooks.values()]


def test_discord_needs_no_app_creation_or_config_credential(kit):
    caps = kit.provider.capabilities()
    assert (caps.provider_id, caps.creates_app, caps.requires_config_credential) == ("discord", False, False)


def test_capability_modes_are_automatic_except_redirect_and_private_spaces(kit):
    assert modes(kit.provider.capabilities()) == {
        CAP.set_icon: MODE.automatic, CAP.app_level_credential: MODE.automatic,
        CAP.gateway_redirect: MODE.unsupported, CAP.join_public_space: MODE.automatic,
        CAP.join_private_space: MODE.unsupported, CAP.unattended_refresh: MODE.automatic}


def test_identity_policy_limits(kit):
    policy = kit.provider.capabilities().identity_policy
    assert (policy.app_name_max, policy.display_name_max, policy.username_max) == (32, 80, 80)
    assert (policy.avatar_max_bytes, policy.avatar_min_px) == (10 * 1024 * 1024, 128)


@pytest.mark.parametrize("raw, username", [
    ("My Discord Helper", "My Helper"), ("DISCORD", "pal"), ("Clyde", "pal"), ("cLyDe the bot", "the bot"),
    ("Pal Helper", "Pal Helper")])
def test_username_drops_reserved_words_case_insensitively(kit, raw, username):
    assert projection(kit, raw).username == username


def test_username_is_capped_at_eighty_characters(kit):
    result = projection(kit, "x" * 120)
    assert len(result.username) == 80 and len(result.display_name) == 80 and len(result.app_name) == 32


def test_blank_display_name_falls_back_to_the_bot_name(kit):
    assert projection(kit, "   ").display_name == BOT


def test_identity_projection_reports_avatar_only_when_the_file_exists(avatar_kit):
    with_file = projection(avatar_kit, DISPLAY_NAME, str(avatar_kit.avatar))
    without = projection(avatar_kit, DISPLAY_NAME, None)
    assert with_file.avatar_ref == str(avatar_kit.avatar) and with_file.avatar_bytes == avatar_kit.avatar.stat().st_size
    assert (without.avatar_ref, without.avatar_bytes) == (None, None)


def test_registry_builds_the_discord_provider():
    assert isinstance(chat_providers.provider_for("discord", redirect_url="https://x"), DiscordProvider)
    assert "discord" in chat_providers.registered_provider_ids()


def test_install_makes_the_exact_requests_in_order(kit):
    kit.install()
    category, channel = kit.fake.categories()[0], kit.fake.text_channels()[0]
    assert [(r.method, r.path) for r in kit.fake.requests] == [
        ("GET", "/users/@me"), ("GET", f"/guilds/{GUILD_ID}"), ("GET", "/applications/@me"),
        ("GET", f"/guilds/{GUILD_ID}/members/{BOT_ID}"), ("GET", f"/guilds/{GUILD_ID}/roles"),
        ("GET", f"/guilds/{GUILD_ID}/channels"), ("POST", f"/guilds/{GUILD_ID}/channels"),
        ("POST", f"/guilds/{GUILD_ID}/channels"), ("POST", f"/channels/{channel['id']}/webhooks")]
    assert [r.body for r in kit.fake.calls("POST")] == [
        {"name": "Pal", "type": 4},
        {"name": "pal-helper", "type": 0, "parent_id": category["id"], "topic": "Pal Helper on Pal"},
        {"name": DISPLAY_NAME}]


def test_every_request_is_authorized_as_the_bot(kit):
    kit.install()
    assert {r.authorization for r in kit.fake.requests} == {f"Bot {TOKEN}"}


def test_webhook_carries_the_avatar_as_a_png_data_uri(avatar_kit):
    avatar_kit.install()
    sent = avatar_kit.fake.calls("POST", "/webhooks")[0].body["avatar"]
    assert sent.startswith(PNG_PREFIX)
    image = Image.open(io.BytesIO(base64.b64decode(sent.removeprefix(PNG_PREFIX))))
    assert image.format == "PNG" and image.size == (48, 48)


def test_webhook_has_no_avatar_key_without_an_avatar_file(kit):
    kit.install()
    assert "avatar" not in kit.fake.calls("POST", "/webhooks")[0].body


def test_installation_names_the_guild_and_the_vault_item(kit):
    installation = kit.install()
    assert (installation.id, installation.workspace_id, installation.status) == (
        f"discord-{GUILD_ID}-{BOT}", GUILD_ID, wire.InstallationStatus.active)
    assert installation.provider_id == "discord" and installation.bot == BOT
    assert [item.id for item in kit.vault.list_items()] == installation.vault_item_ids


def test_vault_item_holds_the_webhook_url_under_api_key(kit):
    installation = kit.install()
    assert [kit.webhook_secret(installation)] == secret_urls(kit)


def test_webhook_url_is_only_in_the_vault(kit, caplog):
    caplog.set_level(logging.DEBUG)
    installation = kit.install()
    (url,) = secret_urls(kit)
    token = kit.fake.webhooks[kit.record()["webhook_id"]]["token"]
    surfaces = [installation.model_dump_json(), kit.records_text(), dumps(kit.routes()), kit.config_text(), caplog.text]
    assert [s for s in surfaces if url in s or token in s] == []


def test_webhook_url_stays_out_of_a_failure_after_it_was_created(kit, caplog, monkeypatch):
    caplog.set_level(logging.DEBUG)

    def boom(*_):
        raise RuntimeError("route store down")

    monkeypatch.setattr(kit.provider.routes, "set", boom)
    with pytest.raises(RuntimeError) as raised:
        kit.install()
    token = next(iter(kit.fake.webhooks.values()))["token"]
    assert token not in str(raised.value) and token not in caplog.text


def test_profile_route_is_exactly_the_bots_channel(kit):
    kit.install()
    assert kit.routes() == [route_for(BOT, kit.home_channel())]


def test_reinstalling_does_not_duplicate_the_route_or_reload_again(kit):
    kit.install()
    kit.install()
    assert len(kit.routes()) == 1 and len(kit.route_reloads) == 1


def test_installing_twice_creates_one_channel_one_category_one_webhook(kit):
    first, second = kit.install(), kit.install()
    assert (len(kit.fake.text_channels()), len(kit.fake.categories()), len(kit.fake.webhooks)) == (1, 1, 1)
    assert len(kit.fake.calls("POST", "/webhooks")) == 1 and first.vault_item_ids == second.vault_item_ids


def test_deleted_channel_is_recreated_once_and_the_route_follows(kit):
    kit.install()
    old = kit.home_channel()
    kit.fake.delete_channel(old)
    kit.install()
    kit.install()
    new = kit.home_channel()
    assert new != old and [c["id"] for c in kit.fake.text_channels()] == [new]
    assert kit.routes() == [route_for(BOT, new)]


def test_deleted_channel_gets_a_fresh_webhook_and_vault_item(kit):
    first = kit.install()
    kit.fake.delete_channel(kit.home_channel())
    second = kit.install()
    assert next(iter(kit.fake.webhooks.values()))["channel_id"] == kit.home_channel()
    assert [i.id for i in kit.vault.list_items()] == second.vault_item_ids != first.vault_item_ids


def test_deleted_webhook_is_recreated_and_the_route_is_kept(kit):
    first = kit.install()
    kit.fake.delete_webhook_remote(kit.record()["webhook_id"])
    reloads = len(kit.route_reloads)
    second = kit.install()
    assert len(kit.fake.webhooks) == 1 and len(kit.fake.text_channels()) == 1
    assert second.vault_item_ids != first.vault_item_ids and kit.webhook_secret(second) in secret_urls(kit)
    assert kit.routes() == [route_for(BOT, kit.home_channel())] and len(kit.route_reloads) == reloads


def test_missing_route_is_rewritten_and_reloaded(kit):
    kit.install()
    kit.set_routes([])
    kit.install()
    assert kit.routes() == [route_for(BOT, kit.home_channel())] and len(kit.route_reloads) == 2


def test_missing_vault_item_recreates_the_webhook_and_deletes_the_old_one(kit):
    first = kit.install()
    old_webhook = kit.record()["webhook_id"]
    kit.vault.remove_item(first.vault_item_ids[0])
    second = kit.install()
    assert old_webhook not in kit.fake.webhooks and kit.record()["webhook_id"] in kit.fake.webhooks
    assert [r.path for r in kit.fake.calls("DELETE")] == [f"/webhooks/{old_webhook}"]
    assert len(kit.fake.text_channels()) == 1 and kit.webhook_secret(second) in secret_urls(kit)


def test_reinstall_refreshes_the_webhook_name_in_place(kit):
    kit.install()
    kit.names[BOT] = "Pal Renamed"
    kit.install()
    assert [w["name"] for w in kit.fake.webhooks.values()] == ["Pal Renamed"]


def test_two_bots_with_one_display_name_get_distinct_channels(kit):
    kit.install("pal")
    kit.install("pal2")
    names = sorted(c["name"] for c in kit.fake.text_channels())
    assert names == ["pal-helper", "pal-helper-2"]


def test_each_bot_gets_its_own_route(kit):
    kit.install("pal")
    kit.install("pal2")
    assert kit.routes() == [route_for("pal", kit.home_channel("pal")), route_for("pal2", kit.home_channel("pal2"))]


@pytest.mark.parametrize("existing", ["pal", "PAL", "Pal"])
def test_existing_category_is_reused_whatever_its_case(kit, existing):
    category = kit.fake.add_channel(existing, kind=4)
    kit.install()
    assert [c["id"] for c in kit.fake.categories()] == [category]
    assert kit.fake.text_channels()[0]["parent_id"] == category


def test_non_numeric_server_id_is_rejected_before_any_request(kit):
    with pytest.raises(DiscordSetupError) as raised:
        kit.install(workspace="not-a-number")
    assert (raised.value.reason, kit.fake.requests) == ("bad_server_id", [])


def test_a_failure_after_the_channel_exists_does_not_make_a_second_channel_on_retry(kit):
    kit.fake.deny_webhook_create = True
    with pytest.raises(DiscordSetupError):
        kit.install()

    kit.fake.deny_webhook_create = False
    kit.install()

    text_channels = [c for c in kit.fake.channels.values() if c["type"] == 0]
    assert len(text_channels) == 1
