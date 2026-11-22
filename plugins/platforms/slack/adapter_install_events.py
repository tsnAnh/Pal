from __future__ import annotations

import asyncio
import functools
import logging
from typing import Any

logger = logging.getLogger(__name__)

_PROVIDER_ID = "slack"
_LOST_CODE = "installation_revoked"
_LOST_MESSAGE = "The Slack app was removed from the workspace. Install the bot again from Pal."
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


def _team_of(event: dict, body: dict) -> str:
    return str((body or {}).get("team_id") or (event or {}).get("team") or "")


async def _installation_lost(adapter: Any, team_id: str) -> None:
    from gateway.chat_install_runtime import build_service
    from hermes_constants import get_hermes_home
    bot = _bot(adapter)
    if not team_id or _store().installation_for_workspace(_PROVIDER_ID, team_id, bot) is None:
        return
    try:
        await asyncio.to_thread(build_service(get_hermes_home()).installation_lost, bot, _PROVIDER_ID, team_id)
    except Exception as exc:  # health: allow BLE001 -- cleanup text can carry provider detail and must not stop the adapter from stopping, so only the type is logged
        logger.warning("[Slack] install cleanup after uninstall failed (%s)", type(exc).__name__)
    adapter._set_fatal_error(_LOST_CODE, _LOST_MESSAGE, retryable=False)
    await adapter._notify_fatal_error()


async def on_app_uninstalled(adapter: Any, event: dict, body: dict) -> None:
    await _installation_lost(adapter, _team_of(event, body))


async def on_tokens_revoked(adapter: Any, event: dict, body: dict) -> None:
    team_id = _team_of(event, body)
    revoked = ((event or {}).get("tokens") or {}).get("bot") or []
    if _bot_user_id(adapter, team_id) in revoked:
        await _installation_lost(adapter, team_id)


def event_handlers(adapter: Any) -> tuple[tuple[str, Any], ...]:
    return (
        ("member_joined_channel", functools.partial(on_member_joined, adapter)),
        ("member_left_channel", functools.partial(on_member_left, adapter)),
        ("app_uninstalled", functools.partial(on_app_uninstalled, adapter)),
        ("tokens_revoked", functools.partial(on_tokens_revoked, adapter)),
    )


async def send_install_welcomes(adapter: Any) -> None:
    from gateway.chat_install_service import pending_welcome
    store, bot = _store(), _bot(adapter)
    for team_id in list(getattr(adapter, "_team_clients", {})):
        pending = pending_welcome(store, bot, _PROVIDER_ID, team_id)
        if pending is None:
            continue
        installation, owner = pending
        text = f"Hi, I'm {_display_name(bot)}. Message me here, or mention me in a channel I'm in."
        if not await _post(adapter, owner, text, team_id):
            store.release_welcome(installation.id)


def schedule_identity_retry(adapter: Any) -> None:
    from gateway.chat_identity_sync import retry_pending_identity
    from hermes_constants import get_hermes_home
    retry_pending_identity(_bot(adapter), get_hermes_home())


def schedule_install_welcomes(adapter: Any) -> None:
    task = asyncio.ensure_future(send_install_welcomes(adapter))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)
