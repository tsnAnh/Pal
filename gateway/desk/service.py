from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Any, Optional

from gateway.desk import delivery
from gateway.desk.model import (
    AskPayload,
    DeskItem,
    HandoffPayload,
    ItemKind,
    ItemState,
    Origin,
    Recipient,
    SendPayload,
    item_id_for_call,
    send_digest,
)
from gateway.desk.owner import OwnerContact, desk_settings, owner_contact
from gateway.desk.policy import AMBIGUOUS_REPLY, match_reply
from gateway.desk.store import DeskStore
from gateway.platforms.owner_desk import DeskSendError

logger = logging.getLogger(__name__)

STALE_POSTING_SECONDS = 300.0
RETENTION_SECONDS = 30 * 24 * 3600.0
MAX_RECOVERY_ASKS = 50
AMBIGUOUS_ASK = "ambiguous"


class DecideStatus(Enum):
    APPLIED = "applied"
    STALE = "stale"
    FORBIDDEN = "forbidden"
    NOT_FOUND = "not_found"


@dataclass(frozen=True)
class DecideResult:
    status: DecideStatus
    item: Optional[DeskItem]


@dataclass(frozen=True)
class AskReservation:
    item: DeskItem
    fresh: bool


@dataclass(frozen=True)
class Reply:
    user_id: str
    user_name: str
    text: str
    ts: str


class Desk:
    def __init__(self, home: Path | str, *, runner: Any = None, profile: str = "default",
                 clock: Callable[[], float] = time.time) -> None:
        self.home = Path(home)
        self.runner = runner
        self.profile = profile or "default"
        self._clock = clock
        self.store = DeskStore(self.home, clock)

    @classmethod
    def in_turn(cls) -> Desk:
        from hermes_constants import get_hermes_home, profile_name_for_home
        home = Path(get_hermes_home())
        return cls(home, profile=profile_name_for_home(home) or "default")

    def origin_of_turn(self) -> Origin:
        from tools.approval_context import get_current_session_key
        return Origin(get_current_session_key(default=""), self.profile)

    def begin_ask(self, *, item_id: str, origin: Origin, contact: OwnerContact, target: Recipient, question: str,
                  wait_minutes: int) -> AskReservation:
        now = self._clock()
        item = DeskItem(
            id=item_id, kind=ItemKind.ASK, state=ItemState.POSTING, revision=0, origin=origin,
            owner_id=contact.user_id, platform=target.platform, scope_id=target.scope_id,
            payload=AskPayload(question, target, None), outcome=None, created_at=now,
            expires_at=now + wait_minutes * 60.0, settled_at=None, delivered_at=None)
        fresh = self.store.reserve(item)
        return AskReservation(item if fresh else self.store.get(item_id) or item, fresh)

    def open_ask(self, item: DeskItem, anchor_ts: str) -> Optional[DeskItem]:
        payload = item.payload
        assert isinstance(payload, AskPayload)
        return self.store.transition(item.id, ItemState.POSTING, ItemState.OPEN, revision=item.revision,
                                     payload=replace(payload, anchor_ts=anchor_ts))

    def request_send(self, *, item_id: str, origin: Origin, contact: OwnerContact, to: Recipient, text: str,
                     label: str, wait_for_reply: bool, wait_minutes: Optional[int]) -> DeskItem:
        now = self._clock()
        item = DeskItem(
            id=item_id, kind=ItemKind.SEND, state=ItemState.OPEN, revision=0, origin=origin,
            owner_id=contact.user_id, platform=to.platform, scope_id=to.scope_id,
            payload=SendPayload(to, text, send_digest(to, text), wait_for_reply, wait_minutes, label), outcome=None,
            created_at=now, expires_at=now + desk_settings().decision_timeout_minutes * 60.0, settled_at=None,
            delivered_at=None)
        self.store.reserve(item)
        return self.store.get(item_id) or item

    def request_handoff(self, *, item_id: str, origin: Origin, contact: OwnerContact, payload: HandoffPayload,
                        scope_id: str) -> DeskItem:
        now = self._clock()
        item = DeskItem(
            id=item_id, kind=ItemKind.HANDOFF, state=ItemState.OPEN, revision=0, origin=origin,
            owner_id=contact.user_id, platform=contact.platform, scope_id=scope_id, payload=payload, outcome=None,
            created_at=now, expires_at=now + desk_settings().decision_timeout_minutes * 60.0, settled_at=None,
            delivered_at=None)
        self.store.reserve(item)
        return self.store.get(item_id) or item

    def pending_ask_id(self, platform: str, scope_id: str, conversation_id: str, user_id: str,
                       thread_ts: Optional[str]) -> Optional[str]:
        found = match_reply(self.store.open_asks_for(platform, scope_id, conversation_id, user_id),
                            user_id=user_id, conversation_id=conversation_id, thread_ts=thread_ts)
        if found is AMBIGUOUS_REPLY:
            return AMBIGUOUS_ASK
        return found.id if found is not None else None

    def cancel_session_asks(self, session_key: str) -> int:
        return len(self.store.cancel_open_asks(session_key))

    async def claim_reply(self, ask_id: str, reply: Reply) -> bool:
        item = self.store.get(ask_id)
        if item is None or item.state is not ItemState.OPEN:
            return False
        outcome = {"reply": {"user_id": reply.user_id, "user_name": reply.user_name, "text": reply.text,
                             "ts": reply.ts}}
        settled = self.store.transition(item.id, ItemState.OPEN, ItemState.DONE, revision=item.revision,
                                        outcome=outcome)
        if settled is None:
            return False
        await self.deliver_outcomes()
        return True

    async def decide(self, item_id: str, *, actor_id: str, choice: str,
                     expected_revision: Optional[int] = None) -> DecideResult:
        item = self.store.get(item_id)
        if item is None or item.kind is ItemKind.ASK:
            return DecideResult(DecideStatus.NOT_FOUND, None)
        if not actor_id or actor_id != item.owner_id:
            return DecideResult(DecideStatus.FORBIDDEN, item)
        if item.state is not ItemState.OPEN or (expected_revision is not None and expected_revision != item.revision):
            return DecideResult(DecideStatus.STALE, item)
        approving = choice == delivery.CHOICE_APPROVE
        if not approving and choice != delivery.CHOICE_DECLINE:
            return DecideResult(DecideStatus.NOT_FOUND, item)
        moved = self.store.transition(item.id, ItemState.OPEN, ItemState.APPROVED if approving else ItemState.DECLINED,
                                      revision=item.revision)
        if moved is None:
            return DecideResult(DecideStatus.STALE, self.store.get(item_id))
        if self.runner is None:
            return DecideResult(DecideStatus.APPLIED, moved)
        if approving:
            await self._execute(moved)
        else:
            await self.deliver_outcomes()
            await self.close_cards()
        return DecideResult(DecideStatus.APPLIED, self.store.get(item_id))

    def _adapter(self, item_or_platform: Any, source: Any = None) -> Any:
        platform = item_or_platform if isinstance(item_or_platform, str) else item_or_platform.platform
        return delivery.adapter_for(self.runner, platform, self.profile, source)

    async def _execute(self, item: DeskItem) -> None:
        leased = self.store.transition(item.id, ItemState.APPROVED, ItemState.EXECUTING, revision=item.revision)
        if leased is None:
            return
        if leased.kind is ItemKind.SEND:
            await self._execute_send(leased)
        else:
            await self._execute_handoff(leased)
        await self.deliver_outcomes()
        await self.close_cards()

    async def _execute_send(self, item: DeskItem) -> None:
        payload = item.payload
        assert isinstance(payload, SendPayload)
        adapter = self._adapter(item)
        try:
            posted = await adapter.desk_send(payload.to, payload.text)
        except DeskSendError as exc:
            logger.warning("Desk send %s was refused by the platform: %s", item.id, exc)
            self.store.transition(item.id, ItemState.EXECUTING, ItemState.FAILED, revision=item.revision,
                                  outcome={"error": "refused"})
            return
        except Exception:
            logger.warning("Desk send %s ended without a platform answer; it is not retried", item.id, exc_info=True)
            self.store.transition(item.id, ItemState.EXECUTING, ItemState.UNKNOWN, revision=item.revision)
            return
        if payload.wait_for_reply:
            self._open_follow_up_ask(item, payload, posted)
        self.store.transition(item.id, ItemState.EXECUTING, ItemState.DONE, revision=item.revision,
                              outcome={"ts": posted.get("ts"), "channel": posted.get("channel")}, wake_origin=False)

    def _open_follow_up_ask(self, item: DeskItem, payload: SendPayload, posted: dict) -> None:
        minutes = payload.wait_minutes or desk_settings().ask_timeout_minutes
        target = replace(payload.to, conversation_id=posted.get("channel") or payload.to.conversation_id)
        reservation = self.begin_ask(item_id=item_id_for_call(item.id, "send-ask", ""), origin=item.origin,
                                     contact=OwnerContact(item.platform, item.scope_id, item.owner_id, None),
                                     target=target, question=payload.text, wait_minutes=minutes)
        if reservation.fresh and posted.get("ts"):
            self.open_ask(reservation.item, str(posted["ts"]))

    async def _execute_handoff(self, item: DeskItem) -> None:
        from gateway.wake import WakeNotAccepted
        adapter = self._adapter(item)
        contact = owner_contact(item.platform, item.scope_id)
        name = await adapter.desk_owner_name(contact) if contact is not None else ""
        try:
            await delivery.wake_owner_lane(self.runner, item, name or "the owner")
        except WakeNotAccepted:
            self.store.transition(item.id, ItemState.EXECUTING, ItemState.APPROVED, revision=item.revision)
            return
        except Exception:
            logger.warning("Desk handoff %s could not be admitted; it is not retried", item.id, exc_info=True)
            self.store.transition(item.id, ItemState.EXECUTING, ItemState.UNKNOWN, revision=item.revision)
            return
        self.store.transition(item.id, ItemState.EXECUTING, ItemState.DONE, revision=item.revision,
                              wake_origin=False)

    async def deliver_outcomes(self) -> None:
        from gateway.wake import PERMANENT_REFUSAL_REASONS, WakeNotAccepted
        for item in self.store.undelivered():
            wake = delivery.wake_for(item)
            if wake is None or not item.origin.session_key:
                self.store.mark_delivered(item.id, item.revision)
                continue
            try:
                await delivery.wake_origin(self.runner, item, wake)
            except WakeNotAccepted as exc:
                if exc.reason not in PERMANENT_REFUSAL_REASONS and not exc.permanent:
                    logger.info("Desk outcome %s not admitted yet (%s); it is retried", item.id, exc.reason)
                    continue
                await self._lost(item)
            except delivery.OriginGone:
                await self._lost(item)
            except Exception:
                logger.warning("Desk outcome %s could not be delivered; it is retried", item.id, exc_info=True)
                continue
            self.store.mark_delivered(item.id, item.revision)

    async def _lost(self, item: DeskItem) -> None:
        logger.info("Desk outcome %s has no session to reach; the owner is told instead", item.id)
        if item.kind is not ItemKind.ASK or item.state is not ItemState.DONE:
            return
        contact = owner_contact(item.platform, item.scope_id)
        adapter = self._adapter(item)
        if contact is not None and adapter is not None:
            await adapter.send_owner_card(contact, delivery.lost_reply_notice(item))

    async def post_cards(self) -> None:
        for item in self.store.awaiting_card():
            contact = owner_contact(item.platform, item.scope_id)
            adapter = self._adapter(item)
            if contact is None or adapter is None:
                continue
            ref = await adapter.send_owner_card(contact, delivery.owner_card(item))
            if ref:
                self.store.set_card_ref(item.id, ref)

    async def close_cards(self) -> None:
        for item, ref in self.store.cards_to_close():
            adapter = self._adapter(item)
            if adapter is None:
                continue
            await adapter.close_owner_card(ref, delivery.settled_card_text(item))
            self.store.mark_card_closed(item.id)

    async def tick(self) -> None:
        now = self._clock()
        for item in self.store.stale_posting(before=now - STALE_POSTING_SECONDS):
            self.store.transition(item.id, ItemState.POSTING, ItemState.UNKNOWN, revision=item.revision)
        for item in self.store.due(now):
            self.store.transition(item.id, ItemState.OPEN, ItemState.EXPIRED, revision=item.revision)
        for item in self.store.approved():
            await self._execute(item)
        await self.post_cards()
        await self.deliver_outcomes()
        await self.close_cards()
        self.store.prune(settled_before=now - RETENTION_SECONDS)

    async def recover_stranded(self) -> None:
        for item in self.store.stranded():
            self.store.transition(item.id, ItemState.EXECUTING, ItemState.UNKNOWN, revision=item.revision)
        await self.deliver_outcomes()
        await self.close_cards()

    async def recover_missed_replies(self, adapter: Any, platform: str) -> int:
        claimed = 0
        for item in self.store.open_asks(platform, MAX_RECOVERY_ASKS):
            try:
                found = await adapter.desk_missed_reply(item)
            except Exception:
                logger.warning("Could not look for a missed reply to %s", item.id, exc_info=True)
                continue
            if found and await self.claim_reply(item.id, Reply(found["user_id"], found.get("user_name") or "",
                                                               found["text"], found["ts"])):
                claimed += 1
        return claimed
