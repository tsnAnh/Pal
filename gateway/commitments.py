"""The commitment ledger: promises that outlive a turn, their legal state machine and an append-only event log.

This module is the only writer of the ``commitments`` and ``commitment_events`` tables (the
``commitment-writers`` check enforces it). Every public function takes the profile home and an injected ``now``.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, fields
from enum import Enum
from pathlib import Path
from types import MappingProxyType
from typing import Mapping


class State(str, Enum):
    OPEN = "open"
    IN_PROGRESS = "in_progress"
    BLOCKED = "blocked"
    DONE = "done"
    ABANDONED = "abandoned"


class Actor(str, Enum):
    BOT = "bot"
    OWNER = "owner"


class RefusalCode(str, Enum):
    UNKNOWN = "unknown_commitment"
    REV_CONFLICT = "rev_conflict"
    ILLEGAL_EDGE = "illegal_edge"
    MISSING_FIELDS = "missing_fields"
    KEY_REUSED = "event_key_reused"
    INVALID = "invalid_input"


class Refused(Exception):
    def __init__(self, code: RefusalCode, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


TERMINAL_STATES = frozenset({State.DONE, State.ABANDONED})
EDGES: frozenset[tuple[State, State]] = frozenset({
    (State.OPEN, State.IN_PROGRESS), (State.OPEN, State.BLOCKED), (State.OPEN, State.DONE),
    (State.OPEN, State.ABANDONED),
    (State.IN_PROGRESS, State.IN_PROGRESS), (State.IN_PROGRESS, State.BLOCKED), (State.IN_PROGRESS, State.DONE),
    (State.IN_PROGRESS, State.ABANDONED),
    (State.BLOCKED, State.BLOCKED), (State.BLOCKED, State.IN_PROGRESS), (State.BLOCKED, State.DONE),
    (State.BLOCKED, State.ABANDONED),
})
REQUIRED_FIELDS: Mapping[State, tuple[str, ...]] = MappingProxyType({
    State.BLOCKED: ("blocker_what", "blocker_who", "next_step"),
    State.DONE: ("evidence",),
    State.ABANDONED: ("reason",),
})
STUCK_AFTER_SECONDS = 24 * 60 * 60
STUCK_AFTER_CHECKS = 3
STALE_STATES = frozenset({State.IN_PROGRESS, State.BLOCKED})

PROMPT_RULE = (
    "Work that outlives this turn is a promise: record it with the `commitment` tool when you accept it, update it "
    "when it is blocked with what blocks it, who unblocks it and your prepared next step, and close it with "
    "evidence, or with a reason if you drop it. Your owner hears only when a promise is done, blocked, overdue, "
    "stuck or abandoned; healthy progress stays silent."
)


@dataclass(frozen=True, slots=True)
class Route:
    platform: str | None = None
    chat_id: str | None = None
    thread_id: str | None = None
    chat_type: str | None = None
    session_key: str | None = None
    session_id: str | None = None


@dataclass(frozen=True, slots=True)
class Details:
    note: str | None = None
    next_step: str | None = None
    blocker_what: str | None = None
    blocker_who: str | None = None
    evidence: str | None = None
    reason: str | None = None


@dataclass(frozen=True, slots=True)
class Commitment:
    id: str
    profile: str
    promise: str
    owner_requested: bool
    due_at: float | None
    state: State
    rev: int
    created_at: float
    updated_at: float
    route: Route
    next_step: str | None
    blocker_what: str | None
    blocker_who: str | None
    evidence: str | None
    reason: str | None
    abandoned_by: Actor | None
    checks_since_progress: int

    def overdue(self, now: float) -> bool:
        return self.state not in TERMINAL_STATES and self.due_at is not None and now > self.due_at

    def stuck(self, now: float) -> bool:
        if self.state in TERMINAL_STATES:
            return False
        if self.checks_since_progress >= STUCK_AFTER_CHECKS:
            return True
        return self.state in STALE_STATES and now - self.updated_at >= STUCK_AFTER_SECONDS


@dataclass(frozen=True, slots=True)
class Transition:
    commitment_id: str
    from_state: State | None
    to_state: State
    rev: int
    replayed: bool


@dataclass(frozen=True, slots=True)
class Event:
    seq: int
    event_key: str
    commitment_id: str
    from_state: State | None
    to_state: State
    rev: int
    actor: Actor
    at: float
    detail: dict


def _names(members) -> str:
    return ", ".join(f"'{member.value}'" for member in members)


_TERMINAL_SQL = _names(sorted(TERMINAL_STATES, key=lambda state: state.value))


_DDL = f"""
CREATE TABLE IF NOT EXISTS commitments (
    id TEXT PRIMARY KEY,
    profile TEXT NOT NULL,
    promise TEXT NOT NULL,
    owner_requested INTEGER NOT NULL CHECK (owner_requested IN (0, 1)),
    due_at REAL,
    state TEXT NOT NULL CHECK (state IN ({_names(State)})),
    rev INTEGER NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    route_json TEXT NOT NULL,
    next_step TEXT,
    blocker_what TEXT,
    blocker_who TEXT,
    evidence TEXT,
    reason TEXT,
    abandoned_by TEXT CHECK (abandoned_by IN ({_names(Actor)})),
    checks_since_progress INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_commitments_active ON commitments (created_at)
    WHERE state NOT IN ({_TERMINAL_SQL});
CREATE TABLE IF NOT EXISTS commitment_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    event_key TEXT NOT NULL UNIQUE,
    commitment_id TEXT NOT NULL,
    from_state TEXT,
    to_state TEXT NOT NULL,
    rev INTEGER NOT NULL,
    actor TEXT NOT NULL CHECK (actor IN ({_names(Actor)})),
    at REAL NOT NULL,
    detail_json TEXT NOT NULL DEFAULT '{{}}',
    UNIQUE (commitment_id, rev)
);
CREATE TRIGGER IF NOT EXISTS commitment_events_no_update BEFORE UPDATE ON commitment_events
BEGIN SELECT RAISE(ABORT, 'commitment_events is append-only'); END;
CREATE TRIGGER IF NOT EXISTS commitment_events_no_delete BEFORE DELETE ON commitment_events
BEGIN SELECT RAISE(ABORT, 'commitment_events is append-only'); END;
"""


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(_DDL)


def _connect(home) -> sqlite3.Connection:
    from hermes_cli.sqlite_util import open_db
    return open_db(Path(home).resolve() / "state.db", db_label="state.db (commitments)", busy_timeout_ms=10_000,
                   initialize=_initialize, foreign_keys=False)


@contextmanager
def _immediate(home):
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


def _clean(value: str | None) -> str | None:
    text = (value or "").strip()
    return text or None


def _to_commitment(row: sqlite3.Row) -> Commitment:
    abandoned_by = row["abandoned_by"]
    return Commitment(
        id=row["id"], profile=row["profile"], promise=row["promise"], owner_requested=bool(row["owner_requested"]),
        due_at=row["due_at"], state=State(row["state"]), rev=row["rev"], created_at=row["created_at"],
        updated_at=row["updated_at"], route=Route(**json.loads(row["route_json"])), next_step=row["next_step"],
        blocker_what=row["blocker_what"], blocker_who=row["blocker_who"], evidence=row["evidence"],
        reason=row["reason"], abandoned_by=Actor(abandoned_by) if abandoned_by else None,
        checks_since_progress=row["checks_since_progress"])


def _to_event(row: sqlite3.Row) -> Event:
    return Event(
        seq=row["seq"], event_key=row["event_key"], commitment_id=row["commitment_id"],
        from_state=State(row["from_state"]) if row["from_state"] else None, to_state=State(row["to_state"]),
        rev=row["rev"], actor=Actor(row["actor"]), at=row["at"], detail=json.loads(row["detail_json"]))


def _replay(event: sqlite3.Row) -> Transition:
    return Transition(event["commitment_id"], State(event["from_state"]) if event["from_state"] else None,
                      State(event["to_state"]), event["rev"], True)


def _event_by_key(conn: sqlite3.Connection, event_key: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM commitment_events WHERE event_key = ?", (event_key,)).fetchone()


def _append_event(conn: sqlite3.Connection, *, event_key: str, commitment_id: str, from_state: State | None,
                  to_state: State, rev: int, actor: Actor, at: float, detail: dict) -> None:
    conn.execute(
        "INSERT INTO commitment_events (event_key, commitment_id, from_state, to_state, rev, actor, at, detail_json) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (event_key, commitment_id, from_state.value if from_state else None, to_state.value, rev, actor.value, at,
         json.dumps(detail, ensure_ascii=False, separators=(",", ":"))))


def promise(home, *, event_key: str, profile: str, text: str, owner_requested: bool, due_at: float | None,
            route: Route, now: float, next_step: str | None = None, actor: Actor = Actor.BOT) -> Transition:
    promised = _clean(text)
    if promised is None:
        raise Refused(RefusalCode.INVALID, "A promise needs text.")
    commitment_id = "cm_" + uuid.uuid4().hex[:12]
    detail = {"promise": promised}
    with _immediate(home) as conn:
        earlier = _event_by_key(conn, event_key)
        if earlier is not None:
            if earlier["from_state"] is not None:
                raise Refused(RefusalCode.KEY_REUSED, f"event_key {event_key!r} already moved another commitment.")
            return _replay(earlier)
        conn.execute(
            "INSERT INTO commitments (id, profile, promise, owner_requested, due_at, state, rev, created_at, "
            "updated_at, route_json, next_step) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)",
            (commitment_id, profile, promised, int(owner_requested), due_at, State.OPEN.value, now, now,
             json.dumps({f.name: getattr(route, f.name) for f in fields(Route)}, separators=(",", ":")),
             _clean(next_step)))
        _append_event(conn, event_key=event_key, commitment_id=commitment_id, from_state=None, to_state=State.OPEN,
                      rev=1, actor=actor, at=now, detail=detail)
    return Transition(commitment_id, None, State.OPEN, 1, False)


def _missing(to: State, details: Details) -> list[str]:
    return [name for name in REQUIRED_FIELDS.get(to, ()) if _clean(getattr(details, name)) is None]


def _guard(conn: sqlite3.Connection, commitment_id: str, event_key: str, expected_rev: int, to: State,
           details: Details) -> sqlite3.Row | Transition:
    earlier = _event_by_key(conn, event_key)
    if earlier is not None:
        if earlier["commitment_id"] != commitment_id:
            raise Refused(RefusalCode.KEY_REUSED, f"event_key {event_key!r} already moved another commitment.")
        return _replay(earlier)
    row = conn.execute("SELECT * FROM commitments WHERE id = ?", (commitment_id,)).fetchone()
    if row is None:
        raise Refused(RefusalCode.UNKNOWN, f"No commitment {commitment_id!r}.")
    if expected_rev != row["rev"]:
        raise Refused(RefusalCode.REV_CONFLICT,
                      f"Commitment {commitment_id} is at rev {row['rev']} in state {row['state']}, not rev {expected_rev}.")
    if (State(row["state"]), to) not in EDGES:
        raise Refused(RefusalCode.ILLEGAL_EDGE, f"A {row['state']} commitment cannot become {to.value}.")
    if missing := _missing(to, details):
        raise Refused(RefusalCode.MISSING_FIELDS, f"Moving to {to.value} needs: {', '.join(missing)}.")
    return row


def transition(home, commitment_id: str, *, event_key: str, expected_rev: int, to: State, details: Details,
               actor: Actor, now: float) -> Transition:
    given = {f.name: _clean(getattr(details, f.name)) for f in fields(Details)}
    blocked = to is State.BLOCKED
    with _immediate(home) as conn:
        found = _guard(conn, commitment_id, event_key, expected_rev, to, details)
        if isinstance(found, Transition):
            return found
        rev = found["rev"] + 1
        conn.execute(
            "UPDATE commitments SET state = ?, rev = ?, updated_at = ?, checks_since_progress = 0, "
            "next_step = COALESCE(?, next_step), blocker_what = ?, blocker_who = ?, "
            "evidence = COALESCE(?, evidence), reason = COALESCE(?, reason), abandoned_by = ? WHERE id = ?",
            (to.value, rev, now, given["next_step"], given["blocker_what"] if blocked else None,
             given["blocker_who"] if blocked else None, given["evidence"], given["reason"],
             actor.value if to is State.ABANDONED else None, commitment_id))
        _append_event(conn, event_key=event_key, commitment_id=commitment_id, from_state=State(found["state"]),
                      to_state=to, rev=rev, actor=actor, at=now,
                      detail={name: value for name, value in given.items() if value is not None})
    return Transition(commitment_id, State(found["state"]), to, rev, False)


def record_check(home, commitment_id: str) -> int | None:
    with _immediate(home) as conn:
        updated = conn.execute(
            "UPDATE commitments SET checks_since_progress = checks_since_progress + 1 "
            f"WHERE id = ? AND state NOT IN ({_TERMINAL_SQL}) RETURNING checks_since_progress",
            (commitment_id,)).fetchone()
    return updated[0] if updated is not None else None


def get(home, commitment_id: str) -> Commitment | None:
    conn = _connect(home)
    try:
        row = conn.execute("SELECT * FROM commitments WHERE id = ?", (commitment_id,)).fetchone()
    finally:
        conn.close()
    return _to_commitment(row) if row is not None else None


def list_active(home, *, limit: int = 50) -> list[Commitment]:
    conn = _connect(home)
    try:
        rows = conn.execute(
            f"SELECT * FROM commitments WHERE state NOT IN ({_TERMINAL_SQL}) ORDER BY created_at, id LIMIT ?",
            (limit,)).fetchall()
    finally:
        conn.close()
    return [_to_commitment(row) for row in rows]


def events(home, commitment_id: str) -> list[Event]:
    conn = _connect(home)
    try:
        rows = conn.execute("SELECT * FROM commitment_events WHERE commitment_id = ? ORDER BY seq",
                            (commitment_id,)).fetchall()
    finally:
        conn.close()
    return [_to_event(row) for row in rows]
