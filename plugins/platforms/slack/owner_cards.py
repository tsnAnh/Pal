from __future__ import annotations

import logging
import re
from typing import Any, Optional

from gateway.platforms.owner_desk import DeskSendError

try:
    from slack_sdk.errors import SlackApiError
except ImportError:  # pragma: no cover - the adapter is not loadable without slack_sdk either
    SlackApiError = Exception  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)

APPROVE_ACTION = "hermes_desk_approve"
DECLINE_ACTION = "hermes_desk_decline"
DESK_ACTION = re.compile(rf"^(?:{APPROVE_ACTION}|{DECLINE_ACTION})$")
_CHOICES = {APPROVE_ACTION: "approve", DECLINE_ACTION: "decline"}
_BUTTONS = {"approve": ("Approve", APPROVE_ACTION, "primary"), "decline": ("Decline", DECLINE_ACTION, "danger")}
MISSED_REPLY_PAGE = 50


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _quoted(lines: tuple[str, ...]) -> str:
    return "\n".join("> " + _escape(line).replace("\n", "\n> ") for line in lines)


def _sections(title: str, lines: tuple[str, ...]) -> list[dict]:
    blocks: list[dict] = [{"type": "section", "text": {"type": "mrkdwn", "text": f"*{_escape(title)}*"}}]
    if lines:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": _quoted(lines)}})
    return blocks


def card_blocks(card: Any) -> list[dict]:
    blocks = _sections(card.title, card.lines)
    if card.choices:
        buttons = [{"type": "button", "text": {"type": "plain_text", "text": label}, "action_id": action_id,
                    "style": style, "value": card.item_id}
                   for label, action_id, style in (_BUTTONS[choice] for choice in card.choices)]
        blocks.append({"type": "actions", "block_id": f"desk_{card.item_id}", "elements": buttons})
    return blocks


def _ts_after(ts: str, anchor: str) -> bool:
    try:
        return float(ts) > float(anchor)
    except (TypeError, ValueError):
        return False


class SlackOwnerDeskMixin:
    async def _owner_dm(self, contact: Any) -> Optional[str]:
        channel = await self._ensure_dm_conversation(contact.user_id, team_id=contact.scope_id or None)
        return channel if channel and channel[0] in ("D", "G", "C") else None

    async def send_owner_card(self, contact: Any, card: Any) -> Optional[dict]:
        channel = await self._owner_dm(contact)
        if channel is None:
            return None
        client = self._get_client(channel, team_id=contact.scope_id or None)
        response = await client.chat_postMessage(channel=channel, text=card.title, blocks=card_blocks(card))
        ts = response.get("ts")
        return {"channel": channel, "ts": ts, "team": contact.scope_id, "title": card.title,
                "lines": list(card.lines)} if ts else None

    async def close_owner_card(self, ref: dict, text: str) -> None:
        blocks = _sections(ref.get("title", ""), tuple(ref.get("lines", ())))
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": _escape(text)}]})
        try:
            await self._get_client(ref["channel"], team_id=ref.get("team") or None).chat_update(
                channel=ref["channel"], ts=ref["ts"], text=text, blocks=blocks)
        except Exception:
            logger.warning("[Slack] Could not close an owner card", exc_info=True)

    async def desk_owner_channel(self, contact: Any) -> Optional[str]:
        return await self._owner_dm(contact)

    async def desk_owner_name(self, contact: Any) -> str:
        return await self._resolve_user_name(contact.user_id, team_id=contact.scope_id or "")

    async def desk_send(self, to: Any, text: str) -> dict:
        channel = to.conversation_id
        if not channel and to.user_id:
            channel = await self._ensure_dm_conversation(to.user_id, team_id=to.scope_id or None)
        if not channel:
            raise DeskSendError("no_destination")
        kwargs: dict[str, Any] = {"channel": channel, "text": text}
        if to.thread_ts:
            kwargs["thread_ts"] = to.thread_ts
        try:
            response = await self._get_client(channel, team_id=to.scope_id or None).chat_postMessage(**kwargs)
        except SlackApiError as exc:
            raise DeskSendError(str(getattr(exc, "response", {}).get("error", "refused"))) from exc
        return {"channel": channel, "ts": response.get("ts")}

    async def desk_acknowledge_reply(self, event: Any) -> None:
        source = event.source
        await self._add_reaction(source.chat_id, str(event.message_id), "white_check_mark", source.scope_id or "")

    async def desk_say(self, event: Any, text: str) -> None:
        source = event.source
        client = self._get_client(source.chat_id, team_id=source.scope_id or None)
        await client.chat_postMessage(channel=source.chat_id, text=text, thread_ts=str(event.message_id))

    async def desk_missed_reply(self, item: Any) -> Optional[dict]:
        payload = item.payload
        target = payload.target
        if not payload.anchor_ts or not target.conversation_id or not target.user_id:
            return None
        client = self._get_client(target.conversation_id, team_id=target.scope_id or None)
        pages = [await client.conversations_replies(channel=target.conversation_id, ts=payload.anchor_ts,
                                                    oldest=payload.anchor_ts, limit=MISSED_REPLY_PAGE)]
        if target.direct:
            pages.append(await client.conversations_history(channel=target.conversation_id, oldest=payload.anchor_ts,
                                                            limit=MISSED_REPLY_PAGE))
        found = sorted(
            (m for page in pages for m in (page.get("messages") or [])
             if m.get("user") == target.user_id and not m.get("bot_id") and _ts_after(m.get("ts"), payload.anchor_ts)),
            key=lambda m: float(m["ts"]))
        if not found:
            return None
        message = found[0]
        name = await self._resolve_user_name(target.user_id, target.conversation_id, target.scope_id or "")
        return {"user_id": target.user_id, "user_name": name, "text": str(message.get("text") or ""),
                "ts": str(message["ts"])}

    def _register_desk_actions(self) -> None:
        self._app.action(DESK_ACTION)(self.handle_desk_action)

    async def handle_desk_action(self, ack, body, action) -> None:
        started = await self._begin_interaction(ack, body, action, "desk")
        if started is None:
            return
        _team, action_id, item_id, _message, _ts, _channel, _name, user_id = started
        choice = _CHOICES.get(action_id)
        if choice is None:
            return
        result = await self.decide_owner_card(item_id, user_id, choice)
        logger.info("[Slack] Owner card click: status=%s", getattr(result.status, "value", result.status))
