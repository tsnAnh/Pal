from __future__ import annotations

import contextlib
import json
import os
import sqlite3
import time
from collections.abc import Callable, Iterable, Iterator
from pathlib import Path
from typing import Any, Optional

from gateway.desk.model import (
    TERMINAL_STATES,
    AskPayload,
    DeskItem,
    ItemKind,
    ItemState,
    Origin,
    Payload,
    payload_from_json,
    payload_to_json,
)

DB_NAME = "desk.db"
SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    state TEXT NOT NULL,
    revision INTEGER NOT NULL,
    platform TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    origin_json TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    outcome_json TEXT,
    reply_user TEXT,
    reply_conversation TEXT,
    card_ref_json TEXT,
    card_closed_at REAL,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    settled_at REAL,
    delivered_at REAL
);
CREATE INDEX IF NOT EXISTS open_asks ON items(platform, scope_id, reply_conversation, reply_user)
    WHERE kind = 'ask' AND state = 'open';
CREATE INDEX IF NOT EXISTS undelivered ON items(settled_at) WHERE settled_at IS NOT NULL AND delivered_at IS NULL;
"""

_TERMINAL = tuple(state.value for state in TERMINAL_STATES)


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    if conn.execute("PRAGMA user_version").fetchone()[0] < SCHEMA_VERSION:
        conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")


def _reply_columns(payload: Payload) -> tuple[Optional[str], Optional[str]]:
    if isinstance(payload, AskPayload):
        return payload.target.user_id, payload.target.conversation_id
    return None, None


def _item(row: sqlite3.Row) -> DeskItem:
    kind = ItemKind(row["kind"])
    origin = json.loads(row["origin_json"])
    return DeskItem(
        id=row["id"], kind=kind, state=ItemState(row["state"]), revision=row["revision"],
        origin=Origin(origin["session_key"], origin["profile"]), owner_id=row["owner_id"],
        platform=row["platform"], scope_id=row["scope_id"],
        payload=payload_from_json(kind, json.loads(row["payload_json"])),
        outcome=json.loads(row["outcome_json"]) if row["outcome_json"] else None,
        created_at=row["created_at"], expires_at=row["expires_at"], settled_at=row["settled_at"],
        delivered_at=row["delivered_at"])


class DeskStore:
    def __init__(self, home: Path | str, clock: Callable[[], float] = time.time) -> None:
        self._path = Path(home) / DB_NAME
        self._clock = clock

    def _open(self) -> sqlite3.Connection:
        from hermes_cli.sqlite_util import open_db
        conn = open_db(self._path, db_label=DB_NAME, busy_timeout_ms=10_000, initialize=_initialize)
        with contextlib.suppress(OSError):
            os.chmod(self._path, 0o600)
        return conn

    @contextlib.contextmanager
    def _write(self) -> Iterator[sqlite3.Connection]:
        from hermes_cli.sqlite_util import transaction
        with transaction(self._open(), immediate=True) as conn:
            yield conn

    @contextlib.contextmanager
    def _read(self) -> Iterator[sqlite3.Connection]:
        conn = self._open()
        try:
            yield conn
        finally:
            conn.close()

    def _items(self, where: str, args: Iterable[Any] = ()) -> list[DeskItem]:
        with self._read() as conn:
            return [_item(row) for row in conn.execute(f"SELECT * FROM items WHERE {where} ORDER BY created_at, id",
                                                       tuple(args))]

    def reserve(self, item: DeskItem) -> bool:
        reply_user, reply_conversation = _reply_columns(item.payload)
        with self._write() as conn:
            cursor = conn.execute(
                "INSERT OR IGNORE INTO items (id, kind, state, revision, platform, scope_id, owner_id, origin_json,"
                " payload_json, outcome_json, reply_user, reply_conversation, created_at, expires_at, settled_at,"
                " delivered_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (item.id, item.kind.value, item.state.value, item.revision, item.platform, item.scope_id,
                 item.owner_id, json.dumps({"session_key": item.origin.session_key, "profile": item.origin.profile}),
                 json.dumps(payload_to_json(item.payload)), json.dumps(item.outcome) if item.outcome else None,
                 reply_user, reply_conversation, item.created_at, item.expires_at, item.settled_at,
                 item.delivered_at))
            return cursor.rowcount == 1

    def get(self, item_id: str) -> Optional[DeskItem]:
        found = self._items("id = ?", (item_id,))
        return found[0] if found else None

    def transition(
        self, item_id: str, frm: ItemState, to: ItemState, *, revision: int, outcome: Optional[dict] = None,
        payload: Optional[Payload] = None, expires_at: Optional[float] = None, wake_origin: bool = True,
    ) -> Optional[DeskItem]:
        now = self._clock()
        sets = ["state = ?", "revision = revision + 1"]
        args: list[Any] = [to.value]
        if outcome is not None:
            sets.append("outcome_json = ?")
            args.append(json.dumps(outcome))
        if payload is not None:
            sets.append("payload_json = ?")
            args.append(json.dumps(payload_to_json(payload)))
        if expires_at is not None:
            sets.append("expires_at = ?")
            args.append(expires_at)
        if to in TERMINAL_STATES:
            sets.append("settled_at = ?")
            args.append(now)
            if not wake_origin:
                sets.append("delivered_at = ?")
                args.append(now)
        with self._write() as conn:
            cursor = conn.execute(f"UPDATE items SET {', '.join(sets)} WHERE id = ? AND state = ? AND revision = ?",
                                  (*args, item_id, frm.value, revision))
            if cursor.rowcount != 1:
                return None
            row = conn.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
        return _item(row)

    def open_asks_for(self, platform: str, scope_id: str, conversation_id: str, user_id: str) -> list[DeskItem]:
        return self._items("kind = 'ask' AND state = 'open' AND platform = ? AND scope_id = ? AND "
                           "reply_conversation = ? AND reply_user = ?", (platform, scope_id, conversation_id, user_id))

    def open_asks(self, platform: str, limit: int) -> list[DeskItem]:
        return self._items("kind = 'ask' AND state = 'open' AND platform = ?", (platform,))[:limit]

    def due(self, now: float) -> list[DeskItem]:
        return self._items("state = 'open' AND expires_at <= ?", (now,))

    def stale_posting(self, *, before: float) -> list[DeskItem]:
        return self._items("state = 'posting' AND created_at <= ?", (before,))

    def stranded(self) -> list[DeskItem]:
        return self._items("state = 'executing'")

    def approved(self) -> list[DeskItem]:
        return self._items("state = 'approved'")

    def awaiting_card(self) -> list[DeskItem]:
        return self._items("kind IN ('handoff', 'send') AND state = 'open' AND card_ref_json IS NULL")

    def cards_to_close(self) -> list[tuple[DeskItem, dict]]:
        with self._read() as conn:
            rows = conn.execute(
                f"SELECT * FROM items WHERE card_ref_json IS NOT NULL AND card_closed_at IS NULL AND state IN "
                f"({','.join('?' * len(_TERMINAL))}) ORDER BY created_at", _TERMINAL).fetchall()
        return [(_item(row), json.loads(row["card_ref_json"])) for row in rows]

    def undelivered(self) -> list[DeskItem]:
        return self._items("settled_at IS NOT NULL AND delivered_at IS NULL")

    def set_card_ref(self, item_id: str, ref: dict) -> None:
        with self._write() as conn:
            conn.execute("UPDATE items SET card_ref_json = ? WHERE id = ?", (json.dumps(ref), item_id))

    def card_ref(self, item_id: str) -> Optional[dict]:
        with self._read() as conn:
            row = conn.execute("SELECT card_ref_json FROM items WHERE id = ?", (item_id,)).fetchone()
        return json.loads(row["card_ref_json"]) if row and row["card_ref_json"] else None

    def mark_card_closed(self, item_id: str) -> None:
        with self._write() as conn:
            conn.execute("UPDATE items SET card_closed_at = ? WHERE id = ?", (self._clock(), item_id))

    def mark_delivered(self, item_id: str, revision: int) -> bool:
        with self._write() as conn:
            cursor = conn.execute("UPDATE items SET delivered_at = ? WHERE id = ? AND revision = ? AND "
                                  "delivered_at IS NULL", (self._clock(), item_id, revision))
            return cursor.rowcount == 1

    def listing(self, states: Optional[frozenset[ItemState]] = None,
                kinds: Optional[frozenset[ItemKind]] = None) -> list[DeskItem]:
        clauses, args = ["1 = 1"], []
        for column, values in (("state", states), ("kind", kinds)):
            if values:
                clauses.append(f"{column} IN ({','.join('?' * len(values))})")
                args.extend(sorted(v.value for v in values))
        return self._items(" AND ".join(clauses), args)

    def cancel_open_asks(self, session_key: str) -> list[DeskItem]:
        cancelled = []
        for item in self._items("kind = 'ask' AND state = 'open'"):
            if item.origin.session_key == session_key:
                settled = self.transition(item.id, ItemState.OPEN, ItemState.CANCELLED, revision=item.revision,
                                          wake_origin=False)
                if settled is not None:
                    cancelled.append(settled)
        return cancelled
