from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Optional, Union

from gateway.audience.model import Audience
from gateway.desk.model import AskPayload, DeskItem, ItemKind, ItemState, Recipient


class Outbound(Enum):
    SEND_NOW = "send_now"
    ASK_OWNER = "ask_owner"


class _Ambiguous:
    def __repr__(self) -> str:
        return "AMBIGUOUS_REPLY"


AMBIGUOUS_REPLY = _Ambiguous()


@dataclass(frozen=True)
class TurnFacts:
    audience: Audience
    internal: bool
    actor_is_owner: bool
    carries_member_content: bool
    named_user_ids: frozenset[str]
    named_conversation_ids: frozenset[str]
    owner_id: str
    report_conversation_id: Optional[str]

    @property
    def tainted(self) -> bool:
        return self.carries_member_content or self.audience is Audience.MEMBER


def outbound_decision(turn: TurnFacts, to: Recipient) -> Outbound:
    if turn.audience is Audience.MEMBER:
        return Outbound.ASK_OWNER
    if to.user_id == turn.owner_id or (to.conversation_id and to.conversation_id == turn.report_conversation_id):
        return Outbound.SEND_NOW
    named = to.user_id in turn.named_user_ids or to.conversation_id in turn.named_conversation_ids
    clean_instruction = turn.actor_is_owner and not turn.internal and not turn.carries_member_content
    return Outbound.SEND_NOW if named and clean_instruction else Outbound.ASK_OWNER


def match_reply(
    open_asks: Sequence[DeskItem], *, user_id: str, conversation_id: str, thread_ts: Optional[str],
) -> Union[DeskItem, _Ambiguous, None]:
    mine = [item for item in open_asks
            if item.kind is ItemKind.ASK and item.state is ItemState.OPEN and isinstance(item.payload, AskPayload)
            and item.payload.target.user_id == user_id and item.payload.target.conversation_id == conversation_id]
    if thread_ts is not None:
        return next((item for item in mine if item.payload.anchor_ts == thread_ts), None)
    direct = [item for item in mine if item.payload.target.direct]
    if len(direct) > 1:
        return AMBIGUOUS_REPLY
    return direct[0] if direct else None
