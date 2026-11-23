from __future__ import annotations

import asyncio
import logging
from typing import Any

try:
    import discord
except ImportError:
    discord = None

logger = logging.getLogger(__name__)

DEFAULT_BOT = "default"
MAX_CHOICES = 25
CHOICE_NAME_MAX = 100
DESCRIPTION = "Choose which Pal bot answers this direct message"
BOT_OPTION = "Bot name; leave empty to see who you are talking to"


def _match(raw: str, choices: list[Any]) -> Any | None:
    wanted = raw.strip().lower()
    exact = [choice for choice in choices if choice.name.lower() == wanted]
    if exact:
        return exact[0]
    named = [choice for choice in choices if choice.display_name.lower() == wanted]
    return named[0] if len(named) == 1 else None


class DiscordPalCommandMixin:
    def _register_pal_command(self, tree: Any) -> None:
        try:
            if tree.get_command("pal") is None and self._bots().installed_bots():
                self._add_pal_command(tree)
        except Exception as exc:  # health: allow BLE001 -- /pal is optional; a failure here must not stop the other commands or the connect
            logger.warning("[%s] /pal not registered (%s)", self.name, type(exc).__name__)

    def _add_pal_command(self, tree: Any) -> None:
        async def _autocomplete(interaction: discord.Interaction, current: str) -> list:
            try:
                allowed, _reason = self._evaluate_slash_authorization(interaction)
                if not allowed or not self._is_pal_owner(interaction):
                    return []
                query = (current or "").strip().lower()
                return [
                    discord.app_commands.Choice(name=choice.display_name[:CHOICE_NAME_MAX], value=choice.name)
                    for choice in self._bots().installed_bots()
                    if not query or query in choice.display_name.lower() or query in choice.name.lower()
                ][:MAX_CHOICES]
            except Exception:  # health: allow BLE001 -- autocomplete fails closed with no suggestions
                return []

        @discord.app_commands.describe(bot=BOT_OPTION)
        @discord.app_commands.autocomplete(bot=_autocomplete)
        async def _pal(interaction: discord.Interaction, bot: str = ""):
            await self._handle_pal(interaction, bot)

        tree.add_command(discord.app_commands.Command(name="pal", description=DESCRIPTION, callback=_pal))

    @staticmethod
    async def _pal_reply(interaction: Any, text: str) -> None:
        try:
            await interaction.response.send_message(text, ephemeral=True)
        except Exception as exc:  # health: allow BLE001 -- the interaction may already be answered or expired
            logger.debug("/pal reply not delivered: %s", type(exc).__name__)

    def _is_pal_owner(self, interaction: Any) -> bool:
        user_id = str(getattr(getattr(interaction, "user", None), "id", ""))
        return user_id in self._bots().owner_ids()

    async def _handle_pal(self, interaction: Any, bot: str) -> None:
        if not await self._check_slash_authorization(interaction, "/pal"):
            return
        if not self._is_pal_owner(interaction):
            await self._pal_reply(interaction, "Only the owner can use /pal.")
            return
        if getattr(interaction, "guild_id", None) is not None:
            await self._pal_reply(interaction, "Use /pal in a direct message with me.")
            return
        channel_id = str(interaction.channel_id)
        try:
            await self._pal_apply(interaction, channel_id, bot.strip())
        except Exception as exc:  # health: allow BLE001 -- the owner gets a plain failure, never provider text
            logger.warning("[%s] /pal failed (%s)", self.name, type(exc).__name__)
            await self._pal_reply(interaction, "I couldn't switch bots right now. Try again in a moment.")

    async def _pal_apply(self, interaction: Any, channel_id: str, requested: str) -> None:
        bots = self._bots()
        installed = await asyncio.to_thread(bots.installed_bots)
        listing = ", ".join(choice.display_name for choice in installed) or "none yet"
        if not requested:
            active = await asyncio.to_thread(bots.direct_bot, channel_id)
            current = next((c.display_name for c in installed if c.name == active), None) or (
                active if active else await asyncio.to_thread(bots.default_display_name))
            await self._pal_reply(interaction, f"You're talking to {current}. Bots: {listing}. "
                                               f"Switch with /pal bot:<name>, or /pal bot:{DEFAULT_BOT} for the default bot.")
            return
        if requested.lower() == DEFAULT_BOT:
            target, shown = None, await asyncio.to_thread(bots.default_display_name)
        else:
            choice = _match(requested, installed)
            if choice is None:
                await self._pal_reply(interaction, f"I don't know that bot. Bots: {listing}.")
                return
            target, shown = choice.name, choice.display_name
        async with self._pal_lock():
            await asyncio.to_thread(bots.select_direct_bot, getattr(self, "gateway_runner", None), channel_id, target)
        await self._pal_reply(interaction, f"Now talking to {shown}.")

    def _pal_lock(self) -> asyncio.Lock:
        lock = getattr(self, "_pal_route_lock", None)
        if lock is None:
            lock = self._pal_route_lock = asyncio.Lock()
        return lock
