from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Optional, Sequence

from tools.bot_dm_wire import DeliveryKey
from tools.bot_thread_identity import CounterpartRef
from tools.bot_thread_ledger import AnchoredExchange, Direction

_ROWS_SQL = (
    "SELECT session_id, role, platform_message_id, display_kind, message_uid,"
    " CASE WHEN role = 'tool' AND instr(content, '\"delivery_id\"') > 0 AND length(content) < 16384 THEN content"
    " WHEN role = 'user' THEN substr(content, 1, 400)"
    " WHEN role = 'assistant' AND COALESCE(content, '') = '' AND length(tool_calls) < 65536 THEN tool_calls END AS probe,"
    " tool_call_id"
    " FROM messages WHERE session_id = ? AND active = 1 AND message_uid IS NOT NULL ORDER BY id")


@dataclass(frozen=True, slots=True)
class ChatRow:
    position: int
    role: str
    platform_message_id: Optional[str]
    display_kind: Optional[str]
    uid: str
    probe: Optional[str]
    tool_call_id: Optional[str] = None

    @property
    def is_human(self) -> bool:
        return self.role == "user" and not self.display_kind


@dataclass(slots=True)
class ExchangeLink:
    anchor_uid: str
    position: int
    thread_id: str
    exchange_id: str
    direction: Direction
    counterpart: CounterpartRef
    covered: list[ChatRow] = field(default_factory=list)
    count: int = 1

    @property
    def last_position(self) -> int:
        return max([self.position, *(row.position for row in self.covered)])


def lineage_rows(db, lineage: Sequence[str]) -> list[ChatRow]:
    seen: set[str] = set()
    rows: list[ChatRow] = []
    with db._read_ctx() as conn:
        for session_id in lineage:
            for found in conn.execute(_ROWS_SQL, (session_id,)).fetchall():
                uid = found[4]
                if uid in seen:
                    continue
                seen.add(uid)
                rows.append(ChatRow(len(rows), found[1], found[2], found[3], uid, found[5], found[6]))
    return rows


def _ack(row: ChatRow) -> Optional[tuple[str, Optional[str]]]:
    try:
        ack = json.loads(row.probe or "")
    except ValueError:
        return None
    if not isinstance(ack, dict):
        return None
    key = DeliveryKey.parse(ack.get("delivery_id"))
    if key is None:
        return None
    process_id = ack.get("process_id")
    return key.delivery_id, process_id if isinstance(process_id, str) and process_id else None


@dataclass(slots=True)
class _RowIndex:
    acks: dict[str, tuple[ChatRow, Optional[str], Optional[ChatRow]]] = field(default_factory=dict)
    dm_turns: dict[str, list[ChatRow]] = field(default_factory=dict)
    completions: dict[str, ChatRow] = field(default_factory=dict)
    lone_calls: dict[str, ChatRow] = field(default_factory=dict)


def _lone_call_id(row: ChatRow) -> Optional[str]:
    try:
        calls = json.loads(row.probe or "")
    except ValueError:
        return None
    if not isinstance(calls, list) or len(calls) != 1 or not isinstance(calls[0], dict):
        return None
    call_id = calls[0].get("id")
    return call_id if isinstance(call_id, str) and call_id else None


def _index(rows: Sequence[ChatRow]) -> _RowIndex:
    from tools.process_registry_notifications import completion_process_id
    index = _RowIndex()
    for row in rows:
        if row.role == "tool" and row.probe:
            ack = _ack(row)
            if ack is not None:
                call = index.lone_calls.pop(row.tool_call_id, None) if row.tool_call_id else None
                index.acks.setdefault(ack[0], (row, ack[1], call))
        elif row.role == "user":
            key = DeliveryKey.from_request_id(row.platform_message_id)
            if key is not None:
                index.dm_turns.setdefault(key.delivery_id, []).append(row)
            elif (process_id := completion_process_id(row.probe or "")) is not None:
                index.completions.setdefault(process_id, row)
        elif row.role == "assistant" and row.probe and (call_id := _lone_call_id(row)) is not None:
            index.lone_calls[call_id] = row
    return index


def _turn_rows(rows: Sequence[ChatRow], start: ChatRow, anchors: set[int]) -> list[ChatRow]:
    covered = []
    for row in rows[start.position + 1:]:
        if row.role == "user" and DeliveryKey.from_request_id(row.platform_message_id) is None:
            break
        if row.position not in anchors:
            covered.append(row)
    return covered


def _link_for(exchange: AnchoredExchange, rows: Sequence[ChatRow], index: _RowIndex,
              anchors: set[int]) -> Optional[ExchangeLink]:
    count = 2 if exchange.has_reply else 1
    if exchange.direction is Direction.outbound:
        found = index.acks.get(exchange.delivery_id)
        if found is None:
            return None
        tool_row, process_id, call = found
        covered = [tool_row] if call is None else [call, tool_row]
        if process_id and (wake := index.completions.get(process_id)) is not None:
            covered.append(wake)
        return ExchangeLink(tool_row.uid, tool_row.position, exchange.thread_id, exchange.exchange_id,
                            exchange.direction, exchange.counterpart, covered, count)
    turns = index.dm_turns.get(exchange.delivery_id)
    if not turns:
        return None
    covered = list(turns)
    for turn in turns:
        covered.extend(row for row in _turn_rows(rows, turn, anchors) if row not in covered)
    return ExchangeLink(turns[0].uid, turns[0].position, exchange.thread_id, exchange.exchange_id,
                        exchange.direction, exchange.counterpart, covered, count)


def _anchor_positions(exchanges: Sequence[AnchoredExchange], index: _RowIndex) -> set[int]:
    positions = set()
    for exchange in exchanges:
        if exchange.direction is Direction.outbound and exchange.delivery_id in index.acks:
            positions.add(index.acks[exchange.delivery_id][0].position)
        elif turns := index.dm_turns.get(exchange.delivery_id):
            positions.add(turns[0].position)
    return positions


def _human_between(rows: Sequence[ChatRow], start: int, end: int, covered: set[int]) -> bool:
    return any(row.is_human and row.position not in covered for row in rows[start + 1:end])


def _fold(links: list[ExchangeLink], rows: Sequence[ChatRow]) -> list[ExchangeLink]:
    covered = {row.position for link in links for row in link.covered}
    folded: list[ExchangeLink] = []
    for link in links:
        previous = folded[-1] if folded else None
        if (previous is not None and previous.thread_id == link.thread_id
                and not _human_between(rows, previous.last_position, link.position, covered)):
            previous.covered.extend(row for row in link.covered if row not in previous.covered)
            previous.count += link.count
            continue
        folded.append(link)
    return folded


def project_links(db, lineage: Sequence[str], exchanges: Sequence[AnchoredExchange]) -> list[ExchangeLink]:
    rows = lineage_rows(db, lineage)
    index = _index(rows)
    anchors = _anchor_positions(exchanges, index)
    links = [link for exchange in exchanges if (link := _link_for(exchange, rows, index, anchors)) is not None]
    links.sort(key=lambda link: link.position)
    return _fold(links, rows)
