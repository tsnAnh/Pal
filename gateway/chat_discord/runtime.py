from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from agent.vault_store import VaultError, VaultStore
from hermes_constants import get_default_hermes_root

from .default_profile import ProfileRoutes
from .records import DiscordRecords

logger = logging.getLogger(__name__)

DEFAULT_BOT = "default"
REPAIR_COOLDOWN_S = 60.0


@dataclass(frozen=True)
class WebhookEndpoint:
    bot: str
    channel_id: str
    webhook_id: str
    url: str = field(repr=False)
    username: str | None
    avatar_url: str | None


@dataclass(frozen=True)
class BotChoice:
    name: str
    display_name: str


def _display_name(bot: str) -> str:
    try:
        from gateway.chat_slack.provider import profile_identity
        return profile_identity(bot).display_name or bot
    except Exception:  # health: allow BLE001 -- a profile that cannot be read still keeps its name in the list
        return bot


class DiscordBots:
    def __init__(self, *, records: DiscordRecords | None = None, vault: VaultStore | None = None,
                 routes: ProfileRoutes | None = None, home: Path | None = None,
                 repair: Callable[[str, Path], None] | None = None,
                 display_name: Callable[[str], str] = _display_name,
                 clock: Callable[[], float] = time.monotonic):
        self._records, self._vault, self._routes = records, vault, routes
        self._home, self._repair, self._display_name, self._clock = home, repair, display_name, clock
        self._lock = threading.Lock()
        self._repair_at: dict[str, float] = {}

    @property
    def records(self) -> DiscordRecords:
        if self._records is None:
            self._records = DiscordRecords()
        return self._records

    @property
    def routes(self) -> ProfileRoutes:
        if self._routes is None:
            self._routes = ProfileRoutes()
        return self._routes

    def _vault_store(self) -> VaultStore:
        if self._vault is None:
            self._vault = VaultStore(get_default_hermes_root() / "vault")
        return self._vault

    def _installed(self) -> list[dict[str, Any]]:
        return [record for record in self.records.apps() if record.get("webhook_id") and record.get("channel_id")]

    def bot_channel_ids(self) -> frozenset[str]:
        return frozenset(
            str(channel) for record in self._installed()
            for channel in (record["channel_id"], *record.get("extra_channel_ids", [])))

    def webhook_ids(self) -> frozenset[str]:
        return frozenset(str(record["webhook_id"]) for record in self._installed())

    def installed_bots(self) -> list[BotChoice]:
        names = {str(record["bot"]) for record in self._installed() if record.get("bot")}
        return sorted((BotChoice(name, self._display_name(name)) for name in names),
                      key=lambda choice: choice.display_name.lower())

    def default_display_name(self) -> str:
        return self._display_name(DEFAULT_BOT)

    def endpoint_for(self, channel_id: str) -> WebhookEndpoint | None:
        record = next((r for r in self._installed() if str(r["channel_id"]) == channel_id), None)
        if record is None:
            return None
        bot = str(record.get("bot") or "")
        try:
            url = str(self._vault_store().resolve_secret(str(record.get("webhook_item_id") or "")).get("api_key") or "")
        except VaultError:
            url = ""
        if not url:
            logger.warning("discord webhook secret for bot %s is missing; replies use the Pal app until repaired", bot)
            self.flag_repair(bot)
            return None
        return WebhookEndpoint(bot=bot, channel_id=channel_id, webhook_id=str(record["webhook_id"]), url=url,
                               username=record.get("webhook_name") or None,
                               avatar_url=record.get("webhook_avatar_url") or None)

    def flag_repair(self, bot: str) -> bool:
        now = self._clock()
        with self._lock:
            last = self._repair_at.get(bot)
            if last is not None and now - last < REPAIR_COOLDOWN_S:
                return False
            self._repair_at[bot] = now
        home = self._home or get_default_hermes_root()
        repair = self._repair
        if repair is None:
            from gateway.chat_identity_sync import schedule_identity_sync as repair
        repair(bot, home)
        return True

    def direct_bot(self, channel_id: str) -> str | None:
        return self.routes.direct_bot(channel_id)

    def select_direct_bot(self, runner: Any, channel_id: str, bot: str | None) -> bool:
        changed = self.routes.clear_direct(channel_id) if bot in (None, DEFAULT_BOT) else self.routes.set_direct(channel_id, bot)
        if changed and runner is not None:
            self.routes.apply_in_process(runner)
        return changed
