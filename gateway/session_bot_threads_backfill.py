from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional

from tools.bot_dm_wire import DeliveryKey, parse_live_output, parse_target_label, split_sender_stamp
from tools.bot_thread_identity import CounterpartRef, inbound, outbound_local, outbound_peer, outbound_relay
from tools.bot_thread_ledger import Direction, ExchangeKey, Source, Status, record_message, record_outcome

logger = logging.getLogger(__name__)

DONE_KEY = "bot_threads_backfill_v1"
SLICE_SIZE = 200
BOT_CHAT_TITLE = "Bot Chat"


@dataclass(frozen=True, slots=True)
class _Send:
    delivery_id: str
    counterpart: CounterpartRef
    body: str
    occurred_at: float
    session_id: str
    output: Optional[str]


def _done(db) -> bool:
    with db._read_ctx() as conn:
        return conn.execute("SELECT 1 FROM state_meta WHERE key = ?", (DONE_KEY,)).fetchone() is not None


def _mark_done(db) -> None:
    db._execute_write(lambda conn: conn.execute("INSERT OR REPLACE INTO state_meta (key, value) VALUES (?, 'done')",
                                                (DONE_KEY,)))


def _dm_turn(db, key: DeliveryKey) -> Optional[tuple[float, str]]:
    with db._read_ctx() as conn:
        found = conn.execute("SELECT timestamp, session_id FROM messages WHERE platform_message_id IN (?, ?)"
                             " ORDER BY id LIMIT 1", (key.request_id, key.retry_request_id)).fetchone()
    return (found[0], found[1]) if found else None


def _receipts(home: Path) -> Iterator[dict]:
    from tools.bot_live_delivery import _root
    for path in sorted(_root(home).glob("*.json")):
        try:
            receipt = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if isinstance(receipt, dict):
            yield receipt


def import_receipt(home: Path, db, receipt: dict, roster: list) -> bool:
    from gateway.session_bot_threads import outcome_from_receipt
    exchange = ExchangeKey.of(Direction.inbound, receipt.get("delivery_id"))
    if exchange is None or not receipt.get("admission_id"):
        return False
    turn = _dm_turn(db, exchange.delivery)
    message = str(receipt.get("message") or "")
    stamp = split_sender_stamp(message)
    counterpart = inbound(receipt.get("author"), stamp, roster)
    if turn is None or counterpart is None:
        return False
    occurred_at, session_id = turn
    record_message(home, exchange, counterpart, stamp.body if stamp else message, status=Status.delivered,
                   anchor_session_id=session_id, occurred_at=occurred_at, source=Source.backfill)
    outcome = outcome_from_receipt(receipt)
    if outcome is not None:
        record_outcome(home, exchange, outcome, occurred_at=occurred_at)
    return True


def _local_counterpart(home: Path, handle: str) -> Optional[CounterpartRef]:
    from tools.bot_mode_dm import _resolve_local_name
    from tools.bot_mode_probe import _display_name, _handle, _hermes_root, _roster
    root = _hermes_root(home)
    homes = dict(_roster(root))
    names = list(homes)
    profile = _resolve_local_name(handle, names, root)
    if profile is None:
        return None
    return outbound_local(profile, _handle(profile, names), _display_name(profile, homes[profile], names))


def counterpart_for(home: Path, label: object, target: object, remote: list) -> Optional[CounterpartRef]:
    from tools.bot_thread_ledger import peer_origin
    parsed = parse_target_label(label)
    if parsed is None:
        return None
    if parsed.kind == "peer":
        _peer, _, profile = str(target or "").strip().lstrip("@").partition("/")
        return outbound_peer(parsed.peer, profile or None, peer_origin(home, parsed.peer))
    if parsed.kind == "relay":
        rows = [row for row in remote if row["handle"].lower() == parsed.handle.lower()
                and parsed.connection in (row["connection_label"], row["connection_id"])]
        return outbound_relay(rows[0]) if len(rows) == 1 else None
    return _local_counterpart(home, parsed.handle)


def _calls(rows) -> dict[str, dict]:
    calls = {}
    for row in rows:
        if row["role"] != "assistant" or not row["tool_calls"]:
            continue
        try:
            entries = json.loads(row["tool_calls"])
        except ValueError:
            continue
        for call in entries if isinstance(entries, list) else []:
            function = call.get("function") if isinstance(call, dict) else None
            if isinstance(function, dict) and function.get("name") == "message_agent":
                try:
                    args = json.loads(function.get("arguments") or "{}")
                except ValueError:
                    continue
                if isinstance(args, dict):
                    calls[str(call.get("id"))] = args
    return calls


def _completions(rows) -> dict[str, str]:
    from tools.process_registry_notifications import completion_output, completion_process_id
    outputs = {}
    for row in rows:
        if row["role"] == "user" and (process_id := completion_process_id(row["content"] or "")):
            output = completion_output(row["content"])
            if output is not None:
                outputs.setdefault(process_id, output)
    return outputs


def _lineage_rows(db) -> list:
    bot_chat = db.get_session_by_title(BOT_CHAT_TITLE)
    if bot_chat is None:
        return []
    lineage = db.get_compression_lineage(bot_chat["id"]) or [bot_chat["id"]]
    marks = ",".join("?" * len(lineage))
    with db._read_ctx() as conn:
        return conn.execute(
            "SELECT session_id, role, content, tool_calls, tool_call_id, timestamp FROM messages"
            f" WHERE session_id IN ({marks}) AND ((role = 'assistant' AND tool_calls LIKE '%message_agent%')"
            " OR (role = 'tool' AND instr(content, '\"delivery_id\"') > 0)"
            " OR (role = 'user' AND content LIKE '[IMPORTANT: Background process %')) ORDER BY id",
            tuple(lineage)).fetchall()


def sends(home: Path, db, remote: list) -> list[_Send]:
    rows = _lineage_rows(db)
    calls, completions = _calls(rows), _completions(rows)
    found: dict[str, _Send] = {}
    for row in rows:
        args = calls.get(str(row["tool_call_id"])) if row["role"] == "tool" else None
        if args is None:
            continue
        try:
            ack = json.loads(row["content"])
        except ValueError:
            continue
        key = DeliveryKey.parse(ack.get("delivery_id")) if isinstance(ack, dict) else None
        if key is None or key.delivery_id in found or ack.get("status") != "queued":
            continue
        counterpart = counterpart_for(home, ack.get("to"), args.get("target"), remote)
        body = str(args.get("message") or "").strip()
        if counterpart is None or not body:
            continue
        found[key.delivery_id] = _Send(key.delivery_id, counterpart, body, row["timestamp"], row["session_id"],
                                       completions.get(str(ack.get("process_id") or "")))
    return list(found.values())


def import_send(home: Path, send: _Send) -> None:
    from tools.bot_mode_dm_threads import outcome_from_live_payload
    exchange = ExchangeKey.of(Direction.outbound, send.delivery_id)
    payload = parse_live_output(send.output) if send.output else None
    joined = payload is not None and DeliveryKey.parse(payload.get("delivery_id")) == exchange.delivery
    record_message(home, exchange, send.counterpart, send.body, status=Status.delivered if joined else Status.unknown,
                   anchor_session_id=send.session_id, occurred_at=send.occurred_at, source=Source.backfill)
    if joined:
        record_outcome(home, exchange, outcome_from_live_payload(payload), occurred_at=send.occurred_at)


def _slices(items: list) -> Iterator[list]:
    for start in range(0, len(items), SLICE_SIZE):
        yield items[start:start + SLICE_SIZE]


async def backfill(home: Path, db) -> bool:
    from tools.bot_relay import read_remote_roster
    if await asyncio.to_thread(_done, db):
        return False
    roster = await asyncio.to_thread(read_remote_roster, home)
    receipts = await asyncio.to_thread(lambda: list(_receipts(home)))
    for chunk in _slices(receipts):
        await asyncio.to_thread(lambda c=chunk: [import_receipt(home, db, receipt, roster) for receipt in c])
    for chunk in _slices(await asyncio.to_thread(sends, home, db, roster)):
        await asyncio.to_thread(lambda c=chunk: [import_send(home, send) for send in c])
    await asyncio.to_thread(_mark_done, db)
    return True


def start_backfill(authority) -> None:
    home = Path(authority.db.db_path).resolve().parent

    async def run() -> None:
        try:
            await backfill(home, authority.db)
        except Exception:  # health: allow BLE001 -- a background import must never stop the owner; logged with its traceback
            logger.warning("Bot thread backfill failed for %s", home, exc_info=True)

    authority._bot_thread_backfill = asyncio.get_running_loop().create_task(run())
