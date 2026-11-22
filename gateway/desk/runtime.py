from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

from gateway.desk.service import AMBIGUOUS_ASK, DecideResult, Desk, Reply
from gateway.desk.store import DB_NAME

logger = logging.getLogger(__name__)

AMBIGUOUS_REPLY_NOTICE = "Which question is this for? Please reply directly under the message you are answering."


def _profile_of(home: Path) -> str:
    from hermes_constants import profile_name_for_home
    return profile_name_for_home(home) or "default"


def pending_ask_id_for(source: Any, message_id: Optional[str]) -> Optional[str]:
    from hermes_constants import get_hermes_home
    home = Path(get_hermes_home())
    if not (home / DB_NAME).exists() or not source.user_id or not source.chat_id:
        return None
    thread = source.thread_id if source.thread_id and source.thread_id != (message_id or source.message_id) else None
    return Desk(home, profile=_profile_of(home)).pending_ask_id(
        source.platform.value, source.scope_id or "", source.chat_id, source.user_id, thread)


async def handle_desk_reply(runner: Any, event: Any) -> None:
    from gateway.run import _async_profile_runtime_scope
    source = event.source
    home = runner._authorization_home_for_source(source)
    if home is None:
        from hermes_constants import get_hermes_home
        home = get_hermes_home()
    home = Path(home)
    adapter = runner._delivery_adapter_for(source)
    async with _async_profile_runtime_scope(home):
        desk = Desk(home, runner=runner, profile=_profile_of(home))
        if event.desk_ask_id == AMBIGUOUS_ASK:
            await adapter.desk_say(event, AMBIGUOUS_REPLY_NOTICE)
            return
        reply = Reply(source.user_id or "", source.user_name or "", event.text or "", str(event.message_id or ""))
        if await desk.claim_reply(event.desk_ask_id, reply):
            await adapter.desk_acknowledge_reply(event)
        else:
            logger.info("A reply to a desk question was not claimed: another message already answered it")


async def decide_from_card(runner: Any, adapter: Any, item_id: str, actor_id: str, choice: str) -> DecideResult:
    from gateway.run import _async_profile_runtime_scope
    from hermes_constants import get_process_hermes_home
    from hermes_cli.profiles import get_profile_dir
    profile = getattr(adapter, "_owner_profile", None)
    home = Path(get_profile_dir(profile) if profile else get_process_hermes_home())
    async with _async_profile_runtime_scope(home):
        return await Desk(home, runner=runner, profile=_profile_of(home)).decide(
            item_id, actor_id=actor_id, choice=choice)


def cancel_asks(runner: Any, session_key: str) -> None:
    from gateway.desk.store import DeskStore
    from gateway.run import _cron_tick_profile_homes
    config = getattr(runner, "config", None)
    if config is None:
        return
    try:
        for _name, home in _cron_tick_profile_homes(config):
            if (Path(home) / DB_NAME).exists():
                DeskStore(home).cancel_open_asks(session_key)
    except Exception:
        logger.warning("Could not close the open questions of a session that ended", exc_info=True)


def approval_destination(turn: Any, ctx: Any) -> tuple[Any, Optional[dict]]:
    from gateway.desk.owner import owner_contact
    from gateway.session_context import current_turn_event
    event = current_turn_event()
    if event is None or not (event.internal and event.carries_member_content):
        return ctx._status_chat_id, ctx._status_thread_metadata
    source = ctx.source
    contact = owner_contact(source.platform.value, source.scope_id or "")
    future = turn._schedule(ctx._status_adapter.desk_owner_channel(contact), "Owner approval destination") if contact else None
    channel = future.result(timeout=15) if future is not None else None
    if not channel:
        raise RuntimeError("the owner's direct messages are not reachable for this approval")
    return channel, {"scope_id": contact.scope_id} if contact.scope_id else None


async def recover_missed_replies(runner: Any, adapter: Any, platform: str) -> int:
    from gateway.run import _async_profile_runtime_scope
    from hermes_constants import get_process_hermes_home
    from hermes_cli.profiles import get_profile_dir
    profile = getattr(adapter, "_owner_profile", None)
    home = Path(get_profile_dir(profile) if profile else get_process_hermes_home())
    if not (home / DB_NAME).exists():
        return 0
    async with _async_profile_runtime_scope(home):
        return await Desk(home, runner=runner, profile=_profile_of(home)).recover_missed_replies(adapter, platform)
