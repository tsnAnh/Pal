"""The restart "online" notice names a Pal-installed bot by its own name; every other profile keeps Hermes."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

import gateway.run as gateway_run
from gateway.chat_install_store import ChatInstallStore
from gateway.config import GatewayConfig, HomeChannel, Platform, PlatformConfig
from gateway.platforms.base import SendResult
from hermes_cli.profiles import create_profile, get_profile_dir, write_profile_meta
from tui_gateway.contracts.chat_provider import Installation, InstallationStatus

HERMES_NOTICE = "♻️ Gateway online — Hermes is back and ready."


def home_config(platform: Platform, chat_id: str) -> GatewayConfig:
    return GatewayConfig(platforms={platform: PlatformConfig(
        enabled=True, gateway_restart_notification=True,
        home_channel=HomeChannel(platform=platform, chat_id=chat_id, name=chat_id))})


def stand_in_adapter():
    return SimpleNamespace(send_path_degraded=False,
                           send=AsyncMock(return_value=SendResult(success=True, message_id="notice")))


def install_pal_bot(root: Path, bot: str) -> None:
    ChatInstallStore(root).save_installation(Installation(
        id=f"slack-T1-{bot}", provider_id="slack", bot=bot, workspace_id="T1", workspace_name="Acme",
        status=InstallationStatus.active, created_at=1.0, updated_at=1.0, vault_item_ids=[]), [], "UOWNER")


@pytest.fixture
def fleet(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr(gateway_run, "_hermes_home", root)
    for bot in ("scout", "plain"):
        create_profile(bot, no_alias=True, no_skills=True)
        write_profile_meta(get_profile_dir(bot), display_name=bot.title())
    runner = object.__new__(gateway_run.GatewayRunner)
    runner.config = home_config(Platform.DISCORD, "launch-home")
    runner.adapters = {Platform.DISCORD: stand_in_adapter()}
    runner._profile_configs = {"scout": home_config(Platform.TELEGRAM, "scout-home"),
                               "plain": home_config(Platform.TELEGRAM, "plain-home")}
    runner._profile_adapters = {"scout": {Platform.TELEGRAM: stand_in_adapter()},
                                "plain": {Platform.TELEGRAM: stand_in_adapter()}}
    return SimpleNamespace(runner=runner, root=root)


def sent_text(adapter) -> str:
    adapter.send.assert_awaited_once()
    return adapter.send.await_args.args[1]


@pytest.mark.asyncio
async def test_a_served_pal_bot_is_named_while_other_profiles_keep_the_hermes_notice(fleet):
    install_pal_bot(fleet.root, "scout")
    await fleet.runner._send_home_channel_startup_notifications()
    assert sent_text(fleet.runner._profile_adapters["scout"][Platform.TELEGRAM]) == "♻️ Scout is back online and ready."
    assert sent_text(fleet.runner._profile_adapters["plain"][Platform.TELEGRAM]) == HERMES_NOTICE
    assert sent_text(fleet.runner.adapters[Platform.DISCORD]) == HERMES_NOTICE


@pytest.mark.asyncio
async def test_a_launch_profile_with_a_pal_install_is_named_by_its_display_name(fleet):
    write_profile_meta(fleet.root, display_name="Pal Main")
    install_pal_bot(fleet.root, "default")
    await fleet.runner._send_home_channel_startup_notifications()
    assert sent_text(fleet.runner.adapters[Platform.DISCORD]) == "♻️ Pal Main is back online and ready."
    assert sent_text(fleet.runner._profile_adapters["plain"][Platform.TELEGRAM]) == HERMES_NOTICE
