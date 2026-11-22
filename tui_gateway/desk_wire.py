from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from gateway.desk.model import AskPayload, DeskItem, HandoffPayload, ItemState, Recipient, SendPayload
from gateway.desk.store import DB_NAME, DeskStore
from tui_gateway.contracts.chat_provider import (
    DeskItemKind,
    DeskItemState,
    DeskItemWire,
    DeskPerson,
    DeskPlace,
    DeskRecipient,
)

WAITING_STATES = frozenset({ItemState.OPEN, ItemState.APPROVED, ItemState.EXECUTING})


def _recipient(target: Recipient) -> DeskRecipient:
    return DeskRecipient(user_id=target.user_id, conversation_id=target.conversation_id, direct=target.direct)


def item_wire(item: DeskItem) -> DeskItemWire:
    payload = item.payload
    common = {"id": item.id, "kind": DeskItemKind(item.kind.value), "state": DeskItemState(item.state.value),
              "revision": item.revision, "created_at": item.created_at, "expires_at": item.expires_at}
    if isinstance(payload, HandoffPayload):
        return DeskItemWire(
            **common, requester=DeskPerson(id=payload.requester_id, name=payload.requester_name),
            where=DeskPlace(conversation_id=payload.conversation_id, thread_ts=payload.thread_ts, label=payload.where),
            text=payload.request, why=payload.why or None)
    if isinstance(payload, SendPayload):
        return DeskItemWire(
            **common, where=DeskPlace(conversation_id=payload.to.conversation_id or "", thread_ts=payload.to.thread_ts,
                                      label=payload.label),
            text=payload.text, recipient=_recipient(payload.to))
    assert isinstance(payload, AskPayload)
    return DeskItemWire(
        **common, where=DeskPlace(conversation_id=payload.target.conversation_id or "", thread_ts=payload.target.thread_ts),
        text=payload.question, recipient=_recipient(payload.target))


def listing(home: Path, states: Iterable[DeskItemState] | None, kinds: Iterable[DeskItemKind] | None) -> list[DeskItemWire]:
    if not (Path(home) / DB_NAME).exists():
        return []
    from gateway.desk.model import ItemKind
    wanted_states = frozenset(ItemState(s.value) for s in states) if states else WAITING_STATES
    wanted_kinds = frozenset(ItemKind(k.value) for k in kinds) if kinds else None
    return [item_wire(item) for item in DeskStore(home).listing(wanted_states, wanted_kinds)]
