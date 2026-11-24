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

from gateway.autonomy import ActionClass


class State(str, Enum):
    OPEN = "open"
    IN_PROGRESS = "in_progress"
    BLOCKED = "blocked"
    DONE = "done"
    ABANDONED = "abandoned"


class Actor(str, Enum):
    BOT = "bot"
    OWNER = "owner"
    AUTO = "auto"


class Kind(str, Enum):
    PROMISE = "promise"
    MANDATE = "mandate"
    PROPOSAL = "proposal"


class Trigger(str, Enum):
    PR_OPENED = "pr_opened"
    PR_MERGED = "pr_merged"
    CI_RED = "ci_red"
    GATEWAY_RESTART = "gateway_restart"
    CRON_FAILED = "cron_failed"
    DEADLINE_NEAR = "deadline_near"
    PROMISE_OVERDUE = "promise_overdue"
    OWNER_SILENT = "owner_silent"


class MandateState(str, Enum):
    ACTIVE = "active"
    PAUSED = "paused"


class Standing(str, Enum):
    PROPOSED = "proposed"
    ACTIVE = "active"
    PAUSED = "paused"
    DISMISSED = "dismissed"


class MandateMove(str, Enum):
    ACCEPT = "accept"
    PAUSE = "pause"
    RESUME = "resume"
    DISMISS = "dismiss"


class RefusalCode(str, Enum):
    UNKNOWN = "unknown_commitment"
    REV_CONFLICT = "rev_conflict"
    ILLEGAL_EDGE = "illegal_edge"
    MISSING_FIELDS = "missing_fields"
    KEY_REUSED = "event_key_reused"
    INVALID = "invalid_input"
    OWNER_ONLY = "owner_only"
    NOT_PRIMARY = "not_primary_profile"


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
MANDATE_EDGES: Mapping[tuple[Standing, MandateMove], Standing] = MappingProxyType({
    (Standing.PROPOSED, MandateMove.ACCEPT): Standing.ACTIVE,
    (Standing.ACTIVE, MandateMove.PAUSE): Standing.PAUSED,
    (Standing.PAUSED, MandateMove.RESUME): Standing.ACTIVE,
    (Standing.PROPOSED, MandateMove.DISMISS): Standing.DISMISSED,
    (Standing.ACTIVE, MandateMove.DISMISS): Standing.DISMISSED,
    (Standing.PAUSED, MandateMove.DISMISS): Standing.DISMISSED,
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
    kind: Kind = Kind.PROMISE
    trigger: Trigger | None = None
    action_class: ActionClass | None = None
    done_when: str | None = None
    mandate_state: MandateState | None = None
    hits: int = 0
    dismissed: int = 0
    last_fired: float | None = None

    @property
    def standing(self) -> Standing | None:
        if self.kind is Kind.PROMISE:
            return None
        if self.state is State.ABANDONED:
            return Standing.DISMISSED
        return Standing.PROPOSED if self.kind is Kind.PROPOSAL else Standing(self.mandate_state.value)

    def overdue(self, now: float) -> bool:
        return (self.kind is Kind.PROMISE and self.state not in TERMINAL_STATES and self.due_at is not None
                and now > self.due_at)

    def stuck(self, now: float) -> bool:
        if self.kind is not Kind.PROMISE or self.state in TERMINAL_STATES:
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


_MANDATE_COLUMNS = (
    ("kind", f"TEXT NOT NULL DEFAULT '{Kind.PROMISE.value}' CHECK (kind IN ({_names(Kind)}))"),
    ("trigger", f"TEXT CHECK (trigger IN ({_names(Trigger)}))"),
    ("action_class", f"TEXT CHECK (action_class IN ({_names(ActionClass)}))"),
    ("done_when", "TEXT"),
    ("mandate_state", f"TEXT CHECK (mandate_state IN ({_names(MandateState)}))"),
    ("hits", "INTEGER NOT NULL DEFAULT 0"),
    ("dismissed", "INTEGER NOT NULL DEFAULT 0"),
    ("last_fired", "REAL"),
)
_MANDATE_COLUMN_SQL = ",\n    ".join(f"{name} {ddl}" for name, ddl in _MANDATE_COLUMNS)
_PROMISES_ONLY = f"kind = '{Kind.PROMISE.value}'"
_MANDATE_KINDS_SQL = _names((Kind.MANDATE, Kind.PROPOSAL))


_EVENTS_TABLE = f"""
CREATE TABLE commitment_events (
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
)"""
_EVENT_TRIGGERS = tuple(
    f"CREATE TRIGGER IF NOT EXISTS commitment_events_no_{verb} BEFORE {verb.upper()} ON commitment_events "
    "BEGIN SELECT RAISE(ABORT, 'commitment_events is append-only'); END" for verb in ("update", "delete"))

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
    checks_since_progress INTEGER NOT NULL DEFAULT 0,
    {_MANDATE_COLUMN_SQL}
);
CREATE INDEX IF NOT EXISTS idx_commitments_active ON commitments (created_at)
    WHERE state NOT IN ({_TERMINAL_SQL});
{_EVENTS_TABLE.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS", 1)};
{";".join(_EVENT_TRIGGERS)};
"""


def _events_allow_auto(conn: sqlite3.Connection) -> bool:
    row = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'commitment_events'").fetchone()
    return row is None or f"'{Actor.AUTO.value}'" in row[0]


@contextmanager
def _write_locked(conn: sqlite3.Connection):
    previous = conn.isolation_level
    conn.isolation_level = None
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        conn.execute("COMMIT")
    finally:
        conn.isolation_level = previous


def _widen_event_actors(conn: sqlite3.Connection) -> None:
    """A ledger created before ``Actor.AUTO`` carries a CHECK that refuses it, and SQLite cannot alter a CHECK:
    rebuild the events table once, copying every row, under the same write lock the ledger always takes."""
    if _events_allow_auto(conn):
        return
    with _write_locked(conn):
        if not _events_allow_auto(conn):
            conn.execute("DROP TRIGGER IF EXISTS commitment_events_no_update")
            conn.execute("DROP TRIGGER IF EXISTS commitment_events_no_delete")
            conn.execute("ALTER TABLE commitment_events RENAME TO commitment_events_legacy")
            conn.execute(_EVENTS_TABLE)
            conn.execute("INSERT INTO commitment_events SELECT * FROM commitment_events_legacy")
            conn.execute("DROP TABLE commitment_events_legacy")
            for trigger in _EVENT_TRIGGERS:
                conn.execute(trigger)


def _missing_mandate_columns(conn: sqlite3.Connection) -> list[tuple[str, str]]:
    present = {row[1] for row in conn.execute("PRAGMA table_info(commitments)")}
    return [(name, ddl) for name, ddl in _MANDATE_COLUMNS if name not in present]


def _add_mandate_columns(conn: sqlite3.Connection) -> None:
    """A ledger created before ``Kind`` gains the mandate columns once; its rows stay promises through the defaults."""
    if not _missing_mandate_columns(conn):
        return
    with _write_locked(conn):
        for name, ddl in _missing_mandate_columns(conn):
            conn.execute(f"ALTER TABLE commitments ADD COLUMN {name} {ddl}")


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(_DDL)
    _widen_event_actors(conn)
    _add_mandate_columns(conn)


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


def _mandate_fields(row: sqlite3.Row) -> dict:
    """Absent on a ledger a read-only reader opened before its owner migrated it: every row there is a promise."""
    if "kind" not in row.keys():
        return {}
    return {"kind": Kind(row["kind"]), "trigger": Trigger(row["trigger"]) if row["trigger"] else None,
            "action_class": ActionClass(row["action_class"]) if row["action_class"] else None,
            "done_when": row["done_when"],
            "mandate_state": MandateState(row["mandate_state"]) if row["mandate_state"] else None,
            "hits": row["hits"], "dismissed": row["dismissed"], "last_fired": row["last_fired"]}


def _to_commitment(row: sqlite3.Row) -> Commitment:
    abandoned_by = row["abandoned_by"]
    return Commitment(
        id=row["id"], profile=row["profile"], promise=row["promise"], owner_requested=bool(row["owner_requested"]),
        due_at=row["due_at"], state=State(row["state"]), rev=row["rev"], created_at=row["created_at"],
        updated_at=row["updated_at"], route=Route(**json.loads(row["route_json"])), next_step=row["next_step"],
        blocker_what=row["blocker_what"], blocker_who=row["blocker_who"], evidence=row["evidence"],
        reason=row["reason"], abandoned_by=Actor(abandoned_by) if abandoned_by else None,
        checks_since_progress=row["checks_since_progress"], **_mandate_fields(row))


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
            route: Route, now: float, next_step: str | None = None, actor: Actor = Actor.BOT,
            subject: str | None = None) -> Transition:
    promised = _clean(text)
    if promised is None:
        raise Refused(RefusalCode.INVALID, "A promise needs text.")
    commitment_id = "cm_" + uuid.uuid4().hex[:12]
    detail = {"promise": promised, **({"subject": subject} if subject else {})}
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


def _current(conn: sqlite3.Connection, commitment_id: str, event_key: str, expected_rev: int,
             kinds: frozenset[Kind]) -> sqlite3.Row | Transition:
    earlier = _event_by_key(conn, event_key)
    if earlier is not None:
        if earlier["commitment_id"] != commitment_id:
            raise Refused(RefusalCode.KEY_REUSED, f"event_key {event_key!r} already moved another commitment.")
        return _replay(earlier)
    row = conn.execute("SELECT * FROM commitments WHERE id = ?", (commitment_id,)).fetchone()
    if row is None:
        raise Refused(RefusalCode.UNKNOWN, f"No commitment {commitment_id!r}.")
    if Kind(row["kind"]) not in kinds:
        raise Refused(RefusalCode.ILLEGAL_EDGE, f"{commitment_id} is a {row['kind']}; this move is not for it.")
    if expected_rev != row["rev"]:
        raise Refused(RefusalCode.REV_CONFLICT,
                      f"Commitment {commitment_id} is at rev {row['rev']} in state {row['state']}, not rev {expected_rev}.")
    return row


def _guard(conn: sqlite3.Connection, commitment_id: str, event_key: str, expected_rev: int, to: State,
           details: Details) -> sqlite3.Row | Transition:
    row = _current(conn, commitment_id, event_key, expected_rev, frozenset({Kind.PROMISE}))
    if isinstance(row, Transition):
        return row
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


def _parse(enum, value, name: str):
    try:
        return enum(value)
    except ValueError:
        raise Refused(RefusalCode.INVALID, f"{name} must be one of: {_names(enum).replace(chr(39), '')}.") from None


def require_primary(profile: str) -> None:
    """Standing duties belong to the primary bot only; every other profile refuses their verbs."""
    from hermes_cli.primary_profile import primary_profile_name
    primary = primary_profile_name()
    if profile != primary:
        raise Refused(RefusalCode.NOT_PRIMARY, f"Standing duties belong to the primary bot ({primary}), not {profile}.")


def propose_mandate(home, *, event_key: str, profile: str, text: str, trigger: Trigger | str,
                    action_class: ActionClass | str, done_when: str, owner_requested: bool, route: Route, now: float,
                    actor: Actor = Actor.BOT) -> Transition:
    duty, finished = _clean(text), _clean(done_when)
    if duty is None or finished is None:
        raise Refused(RefusalCode.INVALID, "A standing duty needs text and done_when.")
    when = _parse(Trigger, trigger, "trigger")
    acting = _parse(ActionClass, action_class, "action_class")
    commitment_id = "cm_" + uuid.uuid4().hex[:12]
    detail = {"verb": "propose", "promise": duty, "trigger": when.value, "action_class": acting.value,
              "done_when": finished}
    with _immediate(home) as conn:
        earlier = _event_by_key(conn, event_key)
        if earlier is not None:
            if earlier["from_state"] is not None:
                raise Refused(RefusalCode.KEY_REUSED, f"event_key {event_key!r} already moved another commitment.")
            return _replay(earlier)
        conn.execute(
            "INSERT INTO commitments (id, profile, promise, owner_requested, state, rev, created_at, updated_at, "
            "route_json, kind, trigger, action_class, done_when) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)",
            (commitment_id, profile, duty, int(owner_requested), State.OPEN.value, now, now,
             json.dumps({f.name: getattr(route, f.name) for f in fields(Route)}, separators=(",", ":")),
             Kind.PROPOSAL.value, when.value, acting.value, finished))
        _append_event(conn, event_key=event_key, commitment_id=commitment_id, from_state=None, to_state=State.OPEN,
                      rev=1, actor=actor, at=now, detail=detail)
    return Transition(commitment_id, None, State.OPEN, 1, False)


_STORED_AFTER: Mapping[Standing, tuple[Kind | None, MandateState | None, State]] = MappingProxyType({
    Standing.ACTIVE: (Kind.MANDATE, MandateState.ACTIVE, State.OPEN),
    Standing.PAUSED: (Kind.MANDATE, MandateState.PAUSED, State.OPEN),
    Standing.DISMISSED: (None, None, State.ABANDONED),
})


def _move_mandate(home, commitment_id: str, move: MandateMove, *, event_key: str, expected_rev: int, actor: Actor,
                  now: float, reason: str | None = None) -> Transition:
    if move is MandateMove.ACCEPT and actor is not Actor.OWNER:
        raise Refused(RefusalCode.OWNER_ONLY, "Only your owner accepts a proposal.")
    given = _clean(reason)
    with _immediate(home) as conn:
        found = _current(conn, commitment_id, event_key, expected_rev, frozenset({Kind.MANDATE, Kind.PROPOSAL}))
        if isinstance(found, Transition):
            return found
        row = _to_commitment(found)
        after = MANDATE_EDGES.get((row.standing, move))
        if after is None:
            raise Refused(RefusalCode.ILLEGAL_EDGE, f"A {row.standing.value} duty cannot {move.value}.")
        kind, mandate_state, state = _STORED_AFTER[after]
        rev = row.rev + 1
        conn.execute(
            "UPDATE commitments SET kind = COALESCE(?, kind), mandate_state = COALESCE(?, mandate_state), state = ?, "
            "rev = ?, updated_at = ?, dismissed = dismissed + ?, reason = COALESCE(?, reason), abandoned_by = ? "
            "WHERE id = ?",
            (kind.value if kind else None, mandate_state.value if mandate_state else None, state.value, rev, now,
             int(after is Standing.DISMISSED), given, actor.value if after is Standing.DISMISSED else None,
             commitment_id))
        _append_event(conn, event_key=event_key, commitment_id=commitment_id, from_state=row.state, to_state=state,
                      rev=rev, actor=actor, at=now, detail={"verb": move.value, **({"reason": given} if given else {})})
    return Transition(commitment_id, row.state, state, rev, False)


def accept(home, commitment_id: str, **move) -> Transition:
    return _move_mandate(home, commitment_id, MandateMove.ACCEPT, **move)


def pause(home, commitment_id: str, **move) -> Transition:
    return _move_mandate(home, commitment_id, MandateMove.PAUSE, **move)


def resume(home, commitment_id: str, **move) -> Transition:
    return _move_mandate(home, commitment_id, MandateMove.RESUME, **move)


def dismiss(home, commitment_id: str, **move) -> Transition:
    return _move_mandate(home, commitment_id, MandateMove.DISMISS, **move)


def record_check(home, commitment_id: str) -> int | None:
    with _immediate(home) as conn:
        updated = conn.execute(
            "UPDATE commitments SET checks_since_progress = checks_since_progress + 1 "
            f"WHERE id = ? AND {_PROMISES_ONLY} AND state NOT IN ({_TERMINAL_SQL}) RETURNING checks_since_progress",
            (commitment_id,)).fetchone()
    return updated[0] if updated is not None else None


def get(home, commitment_id: str) -> Commitment | None:
    conn = _connect(home)
    try:
        row = conn.execute("SELECT * FROM commitments WHERE id = ?", (commitment_id,)).fetchone()
    finally:
        conn.close()
    return _to_commitment(row) if row is not None else None


def find_by_event_key(home, event_key: str) -> Commitment | None:
    """The commitment an event moved; never creates the ledger, so a profile that never promised stays untouched."""
    path = Path(home).resolve() / "state.db"
    if not path.is_file():
        return None
    from hermes_cli.sqlite_safe_read import connect_tracked
    conn = connect_tracked(f"{path.as_uri()}?mode=ro", tracking_path=path, uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        if conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'commitment_events'").fetchone() is None:
            return None
        row = conn.execute(
            "SELECT c.* FROM commitments c JOIN commitment_events e ON e.commitment_id = c.id WHERE e.event_key = ?",
            (event_key,)).fetchone()
    finally:
        conn.close()
    return _to_commitment(row) if row is not None else None


def open_with_subject(home, prefix: str) -> list[tuple[Commitment, str]]:
    conn = _connect(home)
    try:
        rows = conn.execute(
            "SELECT c.*, json_extract(e.detail_json, '$.subject') AS subject FROM commitments c "
            "JOIN commitment_events e ON e.commitment_id = c.id AND e.rev = 1 "
            f"WHERE c.{_PROMISES_ONLY} AND c.state NOT IN ({_TERMINAL_SQL}) AND substr(json_extract(e.detail_json, '$.subject'), 1, ?) = ? "
            "ORDER BY c.created_at, c.id", (len(prefix), prefix)).fetchall()
    finally:
        conn.close()
    return [(_to_commitment(row), row["subject"]) for row in rows]


def list_active(home, *, kind: Kind = Kind.PROMISE, limit: int = 50) -> list[Commitment]:
    conn = _connect(home)
    try:
        rows = conn.execute(
            f"SELECT * FROM commitments WHERE kind = ? AND state NOT IN ({_TERMINAL_SQL}) "
            "ORDER BY created_at, id LIMIT ?", (kind.value, limit)).fetchall()
    finally:
        conn.close()
    return [_to_commitment(row) for row in rows]


def list_mandates(home, *, include_dismissed: bool = False, limit: int = 50) -> list[Commitment]:
    conn = _connect(home)
    try:
        rows = conn.execute(
            f"SELECT * FROM commitments WHERE kind IN ({_MANDATE_KINDS_SQL}) "
            f"{'' if include_dismissed else f'AND state NOT IN ({_TERMINAL_SQL}) '}ORDER BY created_at, id LIMIT ?",
            (limit,)).fetchall()
    finally:
        conn.close()
    return [_to_commitment(row) for row in rows]


def list_for_follow_up(home, *, closed_since: float) -> list[Commitment]:
    conn = _connect(home)
    try:
        rows = conn.execute(
            f"SELECT * FROM commitments WHERE {_PROMISES_ONLY} AND (state NOT IN ({_TERMINAL_SQL}) OR updated_at >= ?) "
            "ORDER BY created_at, id",
            (closed_since,)).fetchall()
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


@dataclass(frozen=True, slots=True)
class Outcome:
    commitment_id: str
    created_at: float
    due_at: float | None
    closed: State | None
    closed_by: Actor | None
    closed_at: float | None


def outcomes(conn: sqlite3.Connection, *, as_of: float) -> list[Outcome]:
    promises_only = f"WHERE c.{_PROMISES_ONLY} " if not _missing_mandate_columns(conn) else ""
    rows = conn.execute(
        "SELECT c.id, c.created_at, c.due_at, e.to_state, e.actor, e.at FROM commitments c "
        f"LEFT JOIN commitment_events e ON e.commitment_id = c.id AND e.to_state IN ({_TERMINAL_SQL}) AND e.at <= ? "
        f"{promises_only}ORDER BY c.created_at, c.id", (as_of,)).fetchall()
    return [Outcome(row[0], row[1], row[2], State(row[3]) if row[3] else None, Actor(row[4]) if row[4] else None,
                    row[5]) for row in rows]
