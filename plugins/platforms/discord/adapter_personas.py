from __future__ import annotations

import asyncio
import logging
from typing import Any

try:
    import discord
except ImportError:
    discord = None

from plugins.platforms.discord.webhook_send import PersonaChannel, WebhookClient

logger = logging.getLogger(__name__)


class DiscordPersonaMixin:
    def _bots(self):
        bots = getattr(self, "_discord_bots", None)
        if bots is None:
            from gateway.chat_discord.runtime import DiscordBots
            bots = self._discord_bots = DiscordBots()
        return bots

    def _webhook_client(self) -> WebhookClient:
        client = getattr(self, "_discord_webhook_client", None)
        if client is None:
            client = self._discord_webhook_client = WebhookClient()
        return client

    def _persona_gone(self, persona: Any) -> None:
        self._bots().flag_repair(persona.bot)

    async def _persona_channel(self, channel: Any) -> Any:
        if channel is None or isinstance(channel, discord.DMChannel):
            return channel
        parent = self._get_parent_channel_id(channel)
        try:
            persona = await asyncio.to_thread(self._bots().endpoint_for, parent or str(channel.id))
        except Exception as exc:  # health: allow BLE001 -- a broken lookup must not lose the reply; the Pal app sends it
            logger.warning("discord bot identity lookup failed (%s); sending as the Pal app", type(exc).__name__)
            return channel
        if persona is None:
            return channel
        return PersonaChannel(channel, persona, self._webhook_client(), str(channel.id) if parent else None,
                              self._persona_gone)

    def _bot_channel_ids(self) -> frozenset[str]:
        try:
            return self._bots().bot_channel_ids()
        except Exception as exc:  # health: allow BLE001 -- unreadable records leave every channel mention-gated, as before
            logger.warning("discord bot channels unreadable (%s)", type(exc).__name__)
            return frozenset()

    def _is_own_webhook_message(self, message: Any) -> bool:
        webhook_id = getattr(message, "webhook_id", None)
        if not isinstance(webhook_id, int):
            return False
        try:
            return str(webhook_id) in self._bots().webhook_ids()
        except Exception as exc:  # health: allow BLE001 -- when the records are unreadable the allow_bots gate still applies
            logger.warning("discord webhook ids unreadable (%s)", type(exc).__name__)
            return False
