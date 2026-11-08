from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from functools import partial
from pathlib import Path
from typing import Optional

from pydantic import ValidationError

from gateway.session_contract import SessionRef
from hermes_state_runtime import RuntimeStoreError
from tools.bot_thread_identity import CounterpartRef, Lane
from tools.bot_thread_ledger import Direction, Part, Status, ThreadMessage

BOT_CHAT_TITLE = "Bot Chat"
PREVIEW_CHARS = 140

_FAILURE_COPY = {
    "runtime_offline": "{name} was offline",
    "queued_expired": "{name} didn't pick this up in time",
    "delivery_timeout": "{name} didn't answer in time",
    "agent_blocked": "{name} couldn't take this message",
    "cancelled": "This message was cancelled",
    "missing_config": "{name} isn't set up to answer yet",
    "model_unavailable": "{name}'s model is unavailable",
    "runtime_coordination_required": "{name} was busy in another session",
}
_PENDING_COPY = {Status.pending: "Waiting for {name}", Status.unknown: "{name} may not have received this"}


def _home(authority) -> Path:
    return Path(authority.db.db_path).resolve().parent


def _iso(at: Optional[float]) -> Optional[str]:
    return None if at is None else datetime.fromtimestamp(at, tz=UTC).isoformat(timespec="milliseconds")


def _parse(model, params):
    try:
        return model.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError("invalid_params") from exc


def _authorize_bot_chat(connection, params) -> None:
    from gateway.session_busy_controls import authorize
    db = connection.authority.db
    row = db.get_session_by_title(BOT_CHAT_TITLE)
    if row is None:
        raise RuntimeStoreError("not_found")
    tip = db.get_compression_tip(row["id"]) or row["id"]
    authorize(connection, SessionRef(connection.actor.profile_id, tip), params, "session:read")


class _Roster:
    def __init__(self, home: Path):
        from gateway.session_authorities import served_profile_name
        from tools.bot_mode_probe import _hermes_root, _roster
        from tools.bot_relay import read_remote_roster
        self.home = home
        self.self_profile = served_profile_name(home)
        self.homes = dict(_roster(_hermes_root(home)))
        self.names = list(self.homes)
        self.remote = read_remote_roster(home)

    def _local(self, profile: str, key: str, is_self: bool) -> Optional[dict]:
        from tools.bot_mode_probe import _display_name, _handle
        home = self.homes.get(profile)
        if home is None:
            return None
        return {"key": key, "is_self": is_self, "local_profile": profile,
                "display_name": _display_name(profile, home, self.names), "handle": _handle(profile, self.names),
                "avatar": _avatar(home)}

    @property
    def self_key(self) -> str:
        return f"local:{self.self_profile}"

    def owner(self) -> dict:
        return self._local(self.self_profile, self.self_key, True) or {
            "key": self.self_key, "is_self": True, "local_profile": self.self_profile,
            "display_name": self.self_profile, "handle": self.self_profile, "avatar": _avatar(self.home)}

    def counterpart(self, ref: CounterpartRef) -> dict:
        if ref.lane is Lane.local and (live := self._local(ref.profile, ref.key, False)) is not None:
            return live
        display_name = ref.display_name
        if ref.lane is Lane.relay:
            row = next((r for r in self.remote if r["connection_id"] == ref.origin and r["profile"] == ref.profile), None)
            display_name = (row or {}).get("title") or display_name
        return {"key": ref.key, "is_self": False, "local_profile": None, "display_name": display_name or ref.handle,
                "handle": ref.handle, "avatar": {"has_asset": False, "ui_meta": None}}


def _avatar(home: Path) -> dict:
    import hermes_yaml as yaml
    path = home / "profile.yaml"
    try:
        meta = yaml.safe_load(path.read_text(encoding="utf-8-sig")) if path.is_file() else {}
    except (OSError, ValueError, yaml.YAMLError):
        meta = {}
    ui_meta = meta.get("ui_meta") if isinstance(meta, dict) else None
    bots = ui_meta.get("hermes-bots") if isinstance(ui_meta, dict) else None
    has_asset = any((home / "assets" / f"avatar.{ext}").is_file() for ext in ("png", "jpg", "webp"))
    return {"has_asset": has_asset, "ui_meta": bots if isinstance(bots, dict) else None}


def status_text(message: ThreadMessage, recipient_name: str) -> Optional[str]:
    if message.part is Part.reply:
        return None
    if message.status is Status.failed:
        return _FAILURE_COPY.get(message.reason, "Couldn't reach {name}").format(name=recipient_name)
    copy = _PENDING_COPY.get(message.status)
    return copy.format(name=recipient_name) if copy else None


def _message(message: ThreadMessage, owner: dict, counterpart: dict) -> dict:
    sender, recipient = (owner, counterpart) if message.from_self else (counterpart, owner)
    return {"id": f"btm_{message.seq}", "exchange_id": message.exchange_id, "sender_key": sender["key"],
            "text": message.body, "at": _iso(message.occurred_at), "part": message.part.value,
            "status": message.status.value, "status_text": status_text(message, recipient["display_name"])}


def _read_result(home: Path, page) -> dict:
    roster = _Roster(home)
    owner, counterpart = roster.owner(), roster.counterpart(page.counterpart)
    messages = [_message(message, owner, counterpart) for message in page.messages]
    focus_index = next((i for i, m in enumerate(page.messages) if m.seq == page.focus_seq), None)
    return {"thread_id": page.thread_id, "participants": [owner, counterpart], "messages": messages,
            "focus_index": focus_index,
            "before": page.messages[0].seq if page.has_older and page.messages else None,
            "after": page.messages[-1].seq if page.has_newer and page.messages else None,
            "rev": page.rev, "coverage": "own_side" if page.counterpart.lane is Lane.peer else "both_sides",
            "history_since": _iso(page.history_since), "read_only": True}


async def thread_read(connection, ref, params):
    from tools.bot_thread_ledger import PageRequest, read_page
    from tui_gateway.contracts.canonical_bot_threads import BotThreadReadParams
    parsed = _parse(BotThreadReadParams, params)
    _authorize_bot_chat(connection, params)
    home = _home(connection.authority)
    request = PageRequest(limit=parsed.limit, focus_exchange_id=parsed.focus, before_seq=parsed.before,
                          after_seq=parsed.after, since_rev=parsed.since_rev)
    page = await asyncio.to_thread(read_page, home, parsed.thread_id, request)
    if page is None:
        raise RuntimeStoreError("not_found")
    return await asyncio.to_thread(_read_result, home, page)


def _list_result(home: Path) -> dict:
    from tools.bot_thread_ledger import thread_summaries
    roster = _Roster(home)
    threads = []
    for summary in thread_summaries(home):
        counterpart = roster.counterpart(summary.counterpart)
        threads.append({"thread_id": summary.thread_id, "counterpart": counterpart,
                        "last_at": _iso(summary.last.occurred_at), "last_preview": summary.last.body[:PREVIEW_CHARS],
                        "last_sender_key": roster.self_key if summary.last.from_self else counterpart["key"],
                        "message_count": summary.message_count})
    return {"threads": threads}


async def thread_list(connection, ref, params):
    from tui_gateway.contracts.canonical_bot_threads import BotThreadListParams
    _parse(BotThreadListParams, params)
    _authorize_bot_chat(connection, params)
    return await asyncio.to_thread(_list_result, _home(connection.authority))


def _links_result(db, home: Path, session_id: str, limit: int) -> dict:
    from gateway.session_bot_thread_links import project_links
    from tools.bot_thread_ledger import anchored_exchanges
    lineage = db.get_compression_lineage(session_id) or [session_id]
    links = project_links(db, lineage, anchored_exchanges(home, lineage))
    kept = links[-limit:]
    roster = _Roster(home)
    return {"links": [{"anchor_uid": link.anchor_uid, "thread_id": link.thread_id, "exchange_id": link.exchange_id,
                       "kind": "messaged" if link.direction is Direction.outbound else "message_from",
                       "counterpart": roster.counterpart(link.counterpart),
                       "covered_uids": [row.uid for row in link.covered], "count": link.count} for link in kept],
            "truncated": len(links) > len(kept)}


async def thread_links(connection, ref, params):
    from gateway.session_busy_controls import authorize
    from tui_gateway.contracts.canonical_bot_threads import BotThreadLinksParams
    parsed = _parse(BotThreadLinksParams, params)
    authorize(connection, ref, params, "session:read")
    authority = connection.authority
    return await asyncio.to_thread(_links_result, authority.db, _home(authority), parsed.session_id, parsed.limit)


def handlers(connection):
    return {"bot.thread.list": partial(thread_list, connection), "bot.thread.read": partial(thread_read, connection),
            "bot.thread.links": partial(thread_links, connection)}
