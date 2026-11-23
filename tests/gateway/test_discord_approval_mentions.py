"""Discord approval prompts can opt into owner mentions."""

import os
from types import SimpleNamespace

import pytest

from plugins.platforms.discord.adapter import (
    DiscordAdapter,
    _apply_yaml_config,
)


class _FakeChannel:
    def __init__(self):
        self.sent_kwargs = None

    async def send(self, **kwargs):
        self.sent_kwargs = kwargs
        return SimpleNamespace(id=12345)


class _FakeClient:
    def __init__(self, channel):
        self.channel = channel

    def get_channel(self, channel_id):
        return self.channel



def test_yaml_config_seeds_websocket_health_with_primary_precedence(monkeypatch):
    for key in (
        "HERMES_DISCORD_LIVENESS_INTERVAL_SECONDS",
        "HERMES_DISCORD_LIVENESS_FAILURE_THRESHOLD",
    ):
        monkeypatch.delenv(key, raising=False)

    seeded = _apply_yaml_config(
        {},
        {
            "websocket_liveness_interval_seconds": 11,
            "liveness_interval_seconds": 99,
            "websocket_liveness_failure_threshold": 2,
            "websocket_heartbeat_ack_max_age_seconds": 75,
            "websocket_max_latency_seconds": 30,
        },
    )

    assert os.environ["HERMES_DISCORD_LIVENESS_INTERVAL_SECONDS"] == "11"
    assert os.environ["HERMES_DISCORD_LIVENESS_FAILURE_THRESHOLD"] == "2"
    assert seeded == {
        "websocket_liveness_interval_seconds": 11,
        "websocket_liveness_failure_threshold": 2,
        "websocket_heartbeat_ack_max_age_seconds": 75,
        "websocket_max_latency_seconds": 30,
    }


