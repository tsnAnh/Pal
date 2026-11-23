import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from agent.i18n import t
from gateway.config import PlatformConfig
from plugins.platforms.discord.adapter import DiscordAdapter


def _capture_channel(adapter):
    sent = {}

    async def fake_send(**kwargs):
        sent.update(kwargs)
        return SimpleNamespace(id=1234)

    channel = SimpleNamespace(send=AsyncMock(side_effect=fake_send))
    adapter._client = SimpleNamespace(
        get_channel=lambda _chat_id: channel,
        fetch_channel=AsyncMock(),
    )
    return sent



def _embed_text(embed):
    # Fields are attribute objects on discord.py and dicts on the test stub.
    return (embed.description or "") + "".join(
        str(getattr(f, "value", None) or (f.get("value") if isinstance(f, dict) else "") or "")
        for f in embed.fields)


@pytest.mark.asyncio
async def test_slash_confirm_embed_is_header_only_card():
    """Same rule as the approval prompt: content carries the message once, the embed is a header card."""
    adapter = DiscordAdapter(PlatformConfig(enabled=True, token="***"))
    sent = _capture_channel(adapter)

    await adapter.send_slash_confirm(
        chat_id="555", title="Reset session?", message="This will clear the conversation history.",
        session_key="discord:555", confirm_id="c1")

    assert "clear the conversation history" in sent["content"]
    assert "clear the conversation history" not in _embed_text(sent["embed"])


@pytest.mark.asyncio
async def test_clarify_embed_is_header_only_card():
    adapter = DiscordAdapter(PlatformConfig(enabled=True, token="***"))
    sent = _capture_channel(adapter)

    await adapter.send_clarify(
        chat_id="555", question="Which environment should I deploy to?", choices=["staging", "prod"],
        clarify_id="cl1", session_key="discord:555")

    assert "Which environment should I deploy to?" in sent["content"]
    assert "Which environment should I deploy to?" not in _embed_text(sent["embed"])
