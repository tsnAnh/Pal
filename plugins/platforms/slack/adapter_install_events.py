from __future__ import annotations

import asyncio
import logging
from typing import Any

logger = logging.getLogger(__name__)

_PROVIDER_ID = "slack"
_tasks: set[asyncio.Task] = set()


def _store():
    from gateway.chat_install_store import ChatInstallStore
    from hermes_constants import get_hermes_home
    return ChatInstallStore(get_hermes_home())


def _bot(adapter: Any) -> str:
    return getattr(adapter, "_owner_profile", None) or "default"


def _display_name(bot: str) -> str:
    try:
        from hermes_cli.profiles import get_profile_dir, read_profile_meta
        return read_profile_meta(get_profile_dir(bot)).get("display_name") or bot
    except Exception:  # health: allow BLE001 -- a cosmetic lookup or a best-effort post must not break the adapter, and its text is never logged
        return bot


def _bot_user_id(adapter: Any, team_id: str) -> str | None:
    return getattr(adapter, "_team_bot_user_ids", {}).get(team_id) or getattr(adapter, "_bot_user_id", None)


async def _post(adapter: Any, chat_id: str, text: str, team_id: str) -> bool:
    try:
        result = await adapter.send(chat_id, text, metadata={"team_id": team_id})
    except Exception as exc:  # health: allow BLE001 -- a cosmetic lookup or a best-effort post must not break the adapter, and its text is never logged
        logger.warning("[Slack] install message not sent (%s)", type(exc).__name__)
        return False
    return bool(getattr(result, "success", False))


async def _membership(adapter: Any, event: dict, body: dict, *, joined: bool) -> None:
    from gateway.chat_install_service import bot_joined, bot_left
    team_id = str((event or {}).get("team") or (body or {}).get("team_id") or "")
    channel = str((event or {}).get("channel") or "")
    user = (event or {}).get("user")
    if not (team_id and channel and user) or user != _bot_user_id(adapter, team_id):
        return
    store, bot = _store(), _bot(adapter)
    change = (bot_joined if joined else bot_left)(store, bot, _PROVIDER_ID, team_id, channel)
    if change is None or not change.hello_due:
        return
    hello = f"Hi, I'm {_display_name(bot)}. Mention me here to get started."
    if not await _post(adapter, channel, hello, team_id):
        store.release_hello(change.installation.id, channel)


async def on_member_joined(adapter: Any, event: dict, body: dict) -> None:
    await _membership(adapter, event, body, joined=True)


async def on_member_left(adapter: Any, event: dict, body: dict) -> None:
    await _membership(adapter, event, body, joined=False)


async def send_install_welcomes(adapter: Any) -> None:
    from gateway.chat_install_service import pending_welcome
    store, bot = _store(), _bot(adapter)
    for team_id in list(getattr(adapter, "_team_clients", {})):
        installation = pending_welcome(store, bot, _PROVIDER_ID, team_id)
        if installation is None:
            continue
        text = f"Hi, I'm {_display_name(bot)}. Message me here, or mention me in a channel I'm in."
        if not await _post(adapter, installation.owner_user_id, text, team_id):
            store.release_welcome(installation.id)


def schedule_install_welcomes(adapter: Any) -> None:
    task = asyncio.ensure_future(send_install_welcomes(adapter))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)
