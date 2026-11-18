"""``reload-platform``: a saved channel credential reaches the running gateway without a restart.

The verb tears down one platform's adapter and builds it again from the saved ``.env``/config. The
launch profile goes through the reconnect queue (the watcher that already owns build, connect and
publish); a served profile goes through the same reconcile step a rescan uses. No other adapter of
either kind is touched.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from gateway import control_socket
from gateway.config import Platform
from gateway.run_platform_reload import reload_platform
from tests.gateway.test_multiplex_hot_serve import _Adapter, _boot, _mkprofile, _release_reservations, _runner

NEW_BOT = "rotated-bot-credential-9f3a"
NEW_APP = "rotated-app-credential-9f3a"
SLACK_KEYS = ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_ALLOWED_USERS"]


class _Slack(_Adapter):
    platform = Platform.SLACK


@pytest.fixture
def launch(tmp_path, monkeypatch):
    runner, home = _runner(tmp_path, monkeypatch)
    runner.delivery_router = SimpleNamespace(adapters=runner.adapters)
    runner._ensure_reconnect_watcher_running = MagicMock()
    for key in SLACK_KEYS:
        monkeypatch.setenv(key, "stale-launch-value")
    return runner, home


@pytest.mark.asyncio
async def test_new_tokens_replace_the_launch_adapter_through_the_reconnect_queue(launch):
    runner, home = launch
    old = _Slack("old-token")
    runner.adapters[Platform.SLACK] = old
    other = _Adapter("discord-token")
    runner.adapters[Platform.DISCORD] = other
    (home / ".env").write_text(f"SLACK_BOT_TOKEN={NEW_BOT}\nSLACK_APP_TOKEN={NEW_APP}\n", encoding="utf-8")

    result = await reload_platform(runner, home, "slack", SLACK_KEYS)

    assert result == {"reloaded": True, "connecting": True}
    assert old.disconnected and Platform.SLACK not in runner.adapters
    assert runner.adapters[Platform.DISCORD] is other and not other.disconnected
    queued = runner._failed_platforms[Platform.SLACK]
    assert queued["config"].enabled and queued["config"].token == NEW_BOT and queued["next_retry"] <= queued["queued_at"]
    assert queued["predecessor"] is old
    runner._ensure_reconnect_watcher_running.assert_called_once()


@pytest.mark.asyncio
async def test_removed_tokens_stop_the_launch_adapter_and_queue_nothing(launch):
    runner, home = launch
    old = _Slack("old-token")
    runner.adapters[Platform.SLACK] = old
    (home / ".env").write_text("", encoding="utf-8")
    (home / "config.yaml").write_text("platforms:\n  slack:\n    enabled: false\n", encoding="utf-8")

    result = await reload_platform(runner, home, "slack", SLACK_KEYS)

    assert result == {"reloaded": True, "connecting": False}
    assert old.disconnected and Platform.SLACK not in runner.adapters
    assert Platform.SLACK not in runner._failed_platforms
    runner._ensure_reconnect_watcher_running.assert_not_called()


@pytest.mark.asyncio
async def test_a_queued_retry_with_the_old_token_is_replaced_by_the_new_one(launch):
    runner, home = launch
    runner._failed_platforms[Platform.SLACK] = {"config": SimpleNamespace(token="old"), "attempts": 7, "next_retry": 1e12}
    (home / ".env").write_text(f"SLACK_BOT_TOKEN={NEW_BOT}\nSLACK_APP_TOKEN={NEW_APP}\n", encoding="utf-8")

    await reload_platform(runner, home, "slack", SLACK_KEYS)

    queued = runner._failed_platforms[Platform.SLACK]
    assert queued["config"].token == NEW_BOT and queued["attempts"] == 0


@pytest.mark.asyncio
async def test_unknown_platform_and_unserved_home_are_refused(launch, tmp_path):
    runner, home = launch
    assert (await reload_platform(runner, home, "not-a-platform", []))["reloaded"] is False
    stranger = tmp_path / "elsewhere"
    stranger.mkdir()
    refused = await reload_platform(runner, stranger, "slack", SLACK_KEYS)
    assert refused["reloaded"] is False and "not served" in refused["error"]


@pytest.mark.asyncio
async def test_served_profile_gets_a_rebuilt_adapter_and_its_neighbours_are_untouched(tmp_path, monkeypatch):
    runner, home = _runner(tmp_path, monkeypatch)
    alpha = _mkprofile(home, "alpha", "DISCORD_BOT_TOKEN=alpha-token\n")
    _mkprofile(home, "beta", "DISCORD_BOT_TOKEN=beta-token\n")
    with patch("hermes_cli.profiles.get_active_profile_name", return_value="default"):
        _boot(runner, home)
        await runner._start_secondary_profile_adapters()
        old_alpha = runner._profile_adapters["alpha"][Platform.DISCORD]
        beta = runner._profile_adapters["beta"][Platform.DISCORD]

        (alpha / ".env").write_text("DISCORD_BOT_TOKEN=alpha-rotated\n", encoding="utf-8")
        result = await reload_platform(runner, alpha, "discord", ["DISCORD_BOT_TOKEN"])

        assert result == {"reloaded": True, "connecting": True}
        assert old_alpha.disconnected
        assert runner._profile_adapters["alpha"][Platform.DISCORD].token.strip().endswith("alpha-rotated")
        assert runner._profile_adapters["beta"][Platform.DISCORD] is beta and not beta.disconnected

        (alpha / ".env").write_text("", encoding="utf-8")
        result = await reload_platform(runner, alpha, "discord", ["DISCORD_BOT_TOKEN"])
        assert result["connecting"] is False
        assert Platform.DISCORD not in runner._profile_adapters["alpha"]
        assert runner._profile_adapters["beta"][Platform.DISCORD] is beta


@pytest.mark.asyncio
async def test_the_verb_answers_over_the_real_control_socket(tmp_path, monkeypatch):
    from gateway.run_bootstrap import _start_gateway_start_control_socket
    runner, home = _runner(tmp_path, monkeypatch)
    alpha = _mkprofile(home, "alpha", "DISCORD_BOT_TOKEN=alpha-token\n")
    with patch("hermes_cli.profiles.get_active_profile_name", return_value="default"):
        _boot(runner, home)
        await runner._start_secondary_profile_adapters()
        server = await _start_gateway_start_control_socket(runner)
        assert server is not None
        try:
            (alpha / ".env").write_text("DISCORD_BOT_TOKEN=alpha-rotated\n", encoding="utf-8")
            answer = await asyncio.to_thread(
                control_socket.reload_gateway_platform, home, profile_home=alpha, platform="discord",
                env_keys=["DISCORD_BOT_TOKEN"])
            assert answer == {"reloaded": True, "connecting": True}
            assert runner._profile_adapters["alpha"][Platform.DISCORD].token.strip().endswith("alpha-rotated")
            stranger = await asyncio.to_thread(
                control_socket.reload_gateway_platform, home, profile_home=tmp_path / "x", platform="discord", env_keys=[])
            assert stranger["reloaded"] is False
        finally:
            await server.stop()
