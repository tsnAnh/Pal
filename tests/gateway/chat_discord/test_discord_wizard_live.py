from __future__ import annotations

import pytest

from tests.gateway.chat_discord.fake_discord import GUILD_ID
from tests.gateway.chat_discord.live_discord import BOT_TOKEN, LiveDiscord
from tests.gateway.chat_discord.live_gateway import BOT, Multiplexer
from tests.waiting import wait_until

pytestmark = [pytest.mark.platforms("posix"), pytest.mark.spawns_gateway_lookalike]


def retry(gateway: Multiplexer, state: dict) -> dict:
    return gateway.call("chat.install.advance", provider_id="discord", workspace=GUILD_ID, profile=BOT,
                        event="retry", expected_revision=state["revision"])


def reconnect(gateway: Multiplexer) -> dict:
    return gateway.call("chat.install.reconnect", provider_id="discord", workspace=GUILD_ID, profile=BOT)


def refusal(result: dict) -> tuple[str, str | None]:
    return result["state"]["step"], (result["state"]["error"] or {}).get("reason")


def test_wizard_is_done_only_when_the_adapter_is_online_and_answers(tmp_path):
    with LiveDiscord(refuse_intents=True) as discord, Multiplexer(tmp_path, discord) as gateway:
        instance = gateway.identity["instance_id"]

        result = gateway.run_wizard()
        assert refusal(result) == ("error", "missing_intent")

        discord.refuse_intents, discord.refuse_login = False, True
        result = retry(gateway, result["state"])
        assert refusal(result) == ("error", "invalid_token")

        discord.refuse_login, discord.hidden_channels = False, True
        result = retry(gateway, result["state"])
        assert refusal(result) == ("error", "missing_permission")
        assert result["state"]["error"]["permissions"] == ["View Channel"]

        discord.hidden_channels = False
        result = retry(gateway, result["state"])
        assert refusal(result) == ("ready", None)
        assert discord.online()
        assert gateway.install_status()["adapter"] == {"state": "online", "reason": None}

        channel = gateway.routes()[0]["chat_id"]
        discord.say(channel, "hello there")
        wait_until(lambda: any("LOCAL_ACK" in str(body) for _, body in discord.webhook_posts), timeout=60,
                   interval=.2, what="a reply through the channel webhook")

        gateway.forget_adapter_token()
        wait_until(lambda: not discord.online(), timeout=30, interval=.2, what="the adapter to stop")
        status = gateway.install_status()
        assert status["state"]["step"] == "ready"
        assert status["adapter"]["state"] == "not_started"

        logins = len(discord.identified)
        assert reconnect(gateway)["adapter"] == {"state": "online", "reason": None}
        assert len(discord.identified) == logins + 1
        assert gateway.identity["instance_id"] == instance == gateway.current_instance()

        assert BOT_TOKEN not in gateway.replies_text()
