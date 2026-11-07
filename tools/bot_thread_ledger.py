from __future__ import annotations

import logging
import sqlite3
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Optional, Sequence

from tools.bot_dm_wire import DeliveryKey
from tools.bot_thread_identity import CounterpartRef, relearned

logger = logging.getLogger(__name__)

MAX_EVENTS = 20_000
PRUNE_EVERY_SEQ = 500
BODY_MAX_CHARS = 64_000
SINCE_REV_MAX_ROWS = 500


class Direction(StrEnum):
    outbound = "out"
    inbound = "in"


class Part(StrEnum):
    message = "message"
    reply = "reply"


class Status(StrEnum):
    pending = "pending"
    delivered = "delivered"
    unknown = "unknown"
    answered = "answered"
    failed = "failed"


class Source(StrEnum):
    live = "live"
    backfill = "backfill"


_RANK = {Status.pending: 0, Status.delivered: 1, Status.unknown: 2, Status.answered: 3, Status.failed: 3}
_RANK_SQL = ("CASE {col} WHEN 'pending' THEN 0 WHEN 'delivered' THEN 1 WHEN 'unknown' THEN 2 ELSE 3 END")


@dataclass(frozen=True, slots=True)
class ExchangeKey:
    direction: Direction
    delivery: DeliveryKey

    @classmethod
    def of(cls, direction: Direction, delivery_id: object) -> Optional[ExchangeKey]:
        key = DeliveryKey.parse(delivery_id)
        return cls(direction, key) if key else None

    @property
    def exchange_id(self) -> str:
        return f"{self.direction.value}:{self.delivery.delivery_id}"


@dataclass(frozen=True, slots=True)
class Outcome:
    status: Status
    reply: str = ""
    reason: str = ""

    @classmethod
    def answered(cls, reply: str) -> Outcome:
        return cls(Status.answered, reply or "")

    @classmethod
    def failed(cls, reason: str) -> Outcome:
        return cls(Status.failed, "", _known_reason(reason))

    @classmethod
    def unknown(cls) -> Outcome:
        return cls(Status.unknown)

    @classmethod
    def delivered(cls) -> Outcome:
        return cls(Status.delivered)


@dataclass(frozen=True, slots=True)
class ThreadMessage:
    seq: int
    rev: int
    exchange_id: str
    direction: Direction
    part: Part
    body: str
    occurred_at: float
    status: Status
    reason: str

    @property
    def from_self(self) -> bool:
        return (self.direction is Direction.outbound) == (self.part is Part.message)


@dataclass(frozen=True, slots=True)
class ThreadPage:
    thread_id: str
    counterpart: CounterpartRef
    messages: tuple[ThreadMessage, ...]
    has_older: bool
    has_newer: bool
    focus_seq: Optional[int]
    rev: int
    history_since: Optional[float]
    incremental: bool


@dataclass(frozen=True, slots=True)
class ThreadSummary:
    thread_id: str
    counterpart: CounterpartRef
    last: ThreadMessage
    message_count: int


@dataclass(frozen=True, slots=True)
class AnchoredExchange:
    exchange_id: str
    delivery_id: str
    direction: Direction
    thread_id: str
    counterpart: CounterpartRef
    status: Status
    has_reply: bool
    occurred_at: float


@dataclass(frozen=True, slots=True)
class PageRequest:
    limit: int
    focus_exchange_id: Optional[str] = None
    before_seq: Optional[int] = None
    after_seq: Optional[int] = None
    since_rev: Optional[int] = None


def _known_reason(reason: object) -> str:
    from tools.bot_failure_reasons import ALL_REASONS, HELD_NOT_SENT, UNKNOWN
    code = str(reason or "").strip()
    return code if code in ALL_REASONS or code == HELD_NOT_SENT else UNKNOWN


def _db_path(home: Path | str) -> Path:
    return Path(home).resolve() / "state.db"


def _initialize(conn: sqlite3.Connection) -> None:
    from hermes_state_common import BOT_THREAD_EVENTS_SQL
    conn.executescript(BOT_THREAD_EVENTS_SQL)


def _connect(home: Path | str) -> sqlite3.Connection:
    from hermes_cli.sqlite_util import open_db
    return open_db(_db_path(home), db_label="state.db (bot_thread_events)", busy_timeout_ms=5_000,
                   initialize=_initialize, foreign_keys=False)


@contextmanager
def _immediate(home: Path | str) -> Iterator[sqlite3.Connection]:
    conn = _connect(home)
    try:
        conn.isolation_level = None
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        conn.execute("COMMIT")
    finally:
        conn.close()


@contextmanager
def _reading(home: Path | str) -> Iterator[sqlite3.Connection]:
    conn = _connect(home)
    try:
        yield conn
    finally:
        conn.close()


def _next_rev(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COALESCE(MAX(rev), 0) + 1 FROM bot_thread_events").fetchone()[0])


def _swallow(action: str, home: Path | str, write) -> bool:
    try:
        return bool(write())
    except (sqlite3.Error, OSError, ValueError):
        logger.warning("bot thread ledger %s failed for %s", action, _db_path(home), exc_info=True)
        return False


def record_message(home: Path | str, key: ExchangeKey, counterpart: CounterpartRef, body: str, *, status: Status,
                   anchor_session_id: Optional[str] = None, occurred_at: Optional[float] = None,
                   source: Source = Source.live) -> bool:
    def write() -> bool:
        with _immediate(home) as conn:
            return _upsert_message(conn, key, counterpart, body, status, anchor_session_id,
                                   time.time() if occurred_at is None else occurred_at, source)
    return _swallow("message write", home, write)


def _upsert_message(conn: sqlite3.Connection, key: ExchangeKey, counterpart: CounterpartRef, body: str,
                    status: Status, anchor_session_id: Optional[str], occurred_at: float, source: Source) -> bool:
    current = conn.execute("SELECT status, anchor_session_id FROM bot_thread_events WHERE exchange_id = ? AND part = 'message'",
                           (key.exchange_id,)).fetchone()
    rev = _next_rev(conn)
    if current is None:
        cursor = conn.execute(
            "INSERT INTO bot_thread_events (rev, thread_id, thread_key, exchange_id, delivery_id, direction, part, body,"
            " status, occurred_at, lane, counterpart_json, anchor_session_id, source)"
            " VALUES (?, ?, ?, ?, ?, ?, 'message', ?, ?, ?, ?, ?, ?, ?)",
            (rev, counterpart.thread_id, counterpart.key, key.exchange_id, key.delivery.delivery_id,
             key.direction.value, body[:BODY_MAX_CHARS], status.value, occurred_at, counterpart.lane.value,
             counterpart.to_json(), anchor_session_id, source.value))
        _prune_if_due(conn, int(cursor.lastrowid))
        return True
    moves = _RANK[status] > _RANK[Status(current["status"])]
    fills_anchor = anchor_session_id is not None and current["anchor_session_id"] is None
    if not (moves or fills_anchor):
        return False
    conn.execute(
        "UPDATE bot_thread_events SET rev = ?, status = CASE WHEN ? THEN ? ELSE status END,"
        " anchor_session_id = COALESCE(anchor_session_id, ?) WHERE exchange_id = ? AND part = 'message'",
        (rev, moves, status.value, anchor_session_id, key.exchange_id))
    return True


def record_outcome(home: Path | str, key: ExchangeKey, outcome: Outcome, *, learned_origin: Optional[str] = None,
                   occurred_at: Optional[float] = None) -> bool:
    def write() -> bool:
        with _immediate(home) as conn:
            return _settle(conn, key, outcome, learned_origin, time.time() if occurred_at is None else occurred_at)
    return _swallow("outcome write", home, write)


def _settle(conn: sqlite3.Connection, key: ExchangeKey, outcome: Outcome, learned_origin: Optional[str],
            occurred_at: float) -> bool:
    message = conn.execute("SELECT * FROM bot_thread_events WHERE exchange_id = ? AND part = 'message'",
                           (key.exchange_id,)).fetchone()
    if message is None:
        return False
    changed = False
    rev = _next_rev(conn)
    if _RANK[outcome.status] > _RANK[Status(message["status"])]:
        conn.execute("UPDATE bot_thread_events SET rev = ?, status = ?, reason = ? WHERE seq = ?",
                     (rev, outcome.status.value, outcome.reason, message["seq"]))
        changed = True
    if outcome.status is Status.answered and outcome.reply and message["status"] != Status.failed.value:
        cursor = conn.execute(
            "INSERT OR IGNORE INTO bot_thread_events (rev, thread_id, thread_key, exchange_id, delivery_id, direction,"
            " part, body, status, occurred_at, lane, counterpart_json, anchor_session_id, source)"
            " VALUES (?, ?, ?, ?, ?, ?, 'reply', ?, 'answered', ?, ?, ?, NULL, ?)",
            (rev, message["thread_id"], message["thread_key"], message["exchange_id"], message["delivery_id"],
             message["direction"], outcome.reply[:BODY_MAX_CHARS], max(occurred_at, message["occurred_at"]),
             message["lane"], message["counterpart_json"], message["source"]))
        changed = changed or cursor.rowcount > 0
    if learned_origin and message["thread_key"].startswith("peer:"):
        _relearn_peer(conn, message, learned_origin, rev)
        changed = True
    return changed


def _relearn_peer(conn: sqlite3.Connection, message: sqlite3.Row, origin: str, rev: int) -> None:
    provisional = CounterpartRef.from_json(message["counterpart_json"])
    learned = relearned(provisional, origin)
    conn.execute("UPDATE bot_thread_events SET rev = ?, thread_key = ?, thread_id = ?, counterpart_json = ?"
                 " WHERE thread_key = ?", (rev, learned.key, learned.thread_id, learned.to_json(), message["thread_key"]))
    conn.execute("INSERT INTO bot_thread_peer_origins (peer_name, origin, learned_at) VALUES (?, ?, ?)"
                 " ON CONFLICT(peer_name) DO UPDATE SET origin = excluded.origin, learned_at = excluded.learned_at",
                 (provisional.origin, origin, time.time()))


def peer_origin(home: Path | str, peer_name: str) -> Optional[str]:
    def read() -> Optional[str]:
        with _reading(home) as conn:
            found = conn.execute("SELECT origin FROM bot_thread_peer_origins WHERE peer_name = ?", (peer_name,)).fetchone()
            return found[0] if found else None
    try:
        return read()
    except (sqlite3.Error, OSError):
        logger.warning("bot thread ledger peer origin read failed for %s", _db_path(home), exc_info=True)
        return None


def _prune_if_due(conn: sqlite3.Connection, seq: int) -> None:
    if seq % PRUNE_EVERY_SEQ:
        return
    total = int(conn.execute("SELECT COUNT(*) FROM bot_thread_events").fetchone()[0])
    if total <= MAX_EVENTS:
        return
    conn.execute(
        "DELETE FROM bot_thread_events WHERE exchange_id IN (SELECT exchange_id FROM bot_thread_events"
        " WHERE part = 'message' ORDER BY occurred_at, seq LIMIT ?)", ((total - MAX_EVENTS + 1) // 2 + 1,))


def _message_of(row: sqlite3.Row) -> ThreadMessage:
    return ThreadMessage(seq=row["seq"], rev=row["rev"], exchange_id=row["exchange_id"],
                         direction=Direction(row["direction"]), part=Part(row["part"]), body=row["body"],
                         occurred_at=row["occurred_at"], status=Status(row["status"]), reason=row["reason"])


_COLUMNS = "seq, rev, exchange_id, direction, part, body, occurred_at, status, reason"


def _position(conn: sqlite3.Connection, thread_id: str, where: str, value: object) -> Optional[tuple[float, int]]:
    found = conn.execute(f"SELECT occurred_at, seq FROM bot_thread_events WHERE thread_id = ? AND {where}",
                         (thread_id, value)).fetchone()
    return (found[0], found[1]) if found else None


def _older(conn: sqlite3.Connection, thread_id: str, pos: Optional[tuple[float, int]], limit: int) -> list[sqlite3.Row]:
    bound, args = ("AND (occurred_at, seq) < (?, ?)", pos) if pos else ("", ())
    rows = conn.execute(f"SELECT {_COLUMNS} FROM bot_thread_events WHERE thread_id = ? {bound}"
                        " ORDER BY occurred_at DESC, seq DESC LIMIT ?", (thread_id, *args, limit)).fetchall()
    return rows[::-1]


def _newer(conn: sqlite3.Connection, thread_id: str, pos: tuple[float, int], limit: int, *,
           inclusive: bool = False) -> list[sqlite3.Row]:
    op = ">=" if inclusive else ">"
    return conn.execute(f"SELECT {_COLUMNS} FROM bot_thread_events WHERE thread_id = ? AND (occurred_at, seq) {op} (?, ?)"
                        " ORDER BY occurred_at, seq LIMIT ?", (thread_id, *pos, limit)).fetchall()


def _window(conn: sqlite3.Connection, thread_id: str, request: PageRequest) -> tuple[list, bool, bool, Optional[int]]:
    limit = request.limit
    if request.before_seq is not None:
        pos = _position(conn, thread_id, "seq = ?", request.before_seq)
        rows = _older(conn, thread_id, pos, limit + 1) if pos else []
        return rows[-limit:], len(rows) > limit, pos is not None, None
    if request.after_seq is not None:
        pos = _position(conn, thread_id, "seq = ?", request.after_seq)
        rows = _newer(conn, thread_id, pos, limit + 1) if pos else []
        return rows[:limit], pos is not None, len(rows) > limit, None
    focus = (_position(conn, thread_id, "exchange_id = ? AND part = 'message'", request.focus_exchange_id)
             if request.focus_exchange_id else None)
    if focus is None:
        rows = _older(conn, thread_id, None, limit + 1)
        return rows[-limit:], len(rows) > limit, False, None
    before = _older(conn, thread_id, focus, limit // 2 + 1)
    after = _newer(conn, thread_id, focus, limit - min(len(before), limit // 2) + 1, inclusive=True)
    kept_before = before[-(limit // 2):] if limit // 2 else []
    kept_after = after[:limit - len(kept_before)]
    return kept_before + kept_after, len(before) > len(kept_before), len(after) > len(kept_after), focus[1]


def read_page(home: Path | str, thread_id: str, request: PageRequest) -> Optional[ThreadPage]:
    with _reading(home) as conn:
        newest = conn.execute("SELECT counterpart_json FROM bot_thread_events WHERE thread_id = ?"
                              " ORDER BY seq DESC LIMIT 1", (thread_id,)).fetchone()
        if newest is None:
            return None
        if request.since_rev is not None:
            rows = conn.execute(f"SELECT {_COLUMNS} FROM bot_thread_events WHERE thread_id = ? AND rev > ?"
                                " ORDER BY occurred_at, seq LIMIT ?",
                                (thread_id, request.since_rev, SINCE_REV_MAX_ROWS)).fetchall()
            has_older = has_newer = False
            focus_seq = None
        else:
            rows, has_older, has_newer, focus_seq = _window(conn, thread_id, request)
        return ThreadPage(thread_id=thread_id, counterpart=CounterpartRef.from_json(newest[0]),
                          messages=tuple(map(_message_of, rows)), has_older=has_older, has_newer=has_newer,
                          focus_seq=focus_seq, rev=_revision(conn), history_since=_history_since(conn),
                          incremental=request.since_rev is not None)


def thread_summaries(home: Path | str) -> list[ThreadSummary]:
    with _reading(home) as conn:
        rows = conn.execute(
            f"SELECT {_COLUMNS}, thread_id, counterpart_json, count FROM ("
            f" SELECT {_COLUMNS}, thread_id, counterpart_json, COUNT(*) OVER (PARTITION BY thread_id) AS count,"
            "  ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY occurred_at DESC, seq DESC) AS newest"
            " FROM bot_thread_events) WHERE newest = 1 ORDER BY occurred_at DESC, seq DESC").fetchall()
    return [ThreadSummary(row["thread_id"], CounterpartRef.from_json(row["counterpart_json"]), _message_of(row),
                          int(row["count"])) for row in rows]


def anchored_exchanges(home: Path | str, session_ids: Sequence[str]) -> list[AnchoredExchange]:
    if not session_ids:
        return []
    marks = ",".join("?" * len(session_ids))
    with _reading(home) as conn:
        rows = conn.execute(
            "SELECT m.exchange_id, m.delivery_id, m.direction, m.thread_id, m.counterpart_json, m.status,"
            " m.occurred_at, EXISTS (SELECT 1 FROM bot_thread_events r WHERE r.exchange_id = m.exchange_id"
            " AND r.part = 'reply') AS has_reply FROM bot_thread_events m"
            f" WHERE m.part = 'message' AND m.anchor_session_id IN ({marks}) ORDER BY m.occurred_at, m.seq",
            tuple(session_ids)).fetchall()
    return [AnchoredExchange(row["exchange_id"], row["delivery_id"], Direction(row["direction"]), row["thread_id"],
                             CounterpartRef.from_json(row["counterpart_json"]), Status(row["status"]),
                             bool(row["has_reply"]), row["occurred_at"]) for row in rows]


def _revision(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COALESCE(MAX(rev), 0) FROM bot_thread_events").fetchone()[0])


def _history_since(conn: sqlite3.Connection) -> Optional[float]:
    return conn.execute("SELECT MIN(occurred_at) FROM bot_thread_events").fetchone()[0]


def revision_readonly(db_path: Path) -> Optional[int]:
    from hermes_state_holders import read_only_db_uri
    if not db_path.exists():
        return None
    try:
        conn = sqlite3.connect(read_only_db_uri(db_path), uri=True, timeout=0.05)
    except sqlite3.Error:
        return None
    try:
        return _revision(conn)
    except sqlite3.Error:
        return None
    finally:
        conn.close()
