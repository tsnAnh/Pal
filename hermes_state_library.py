from __future__ import annotations

import contextlib
import hashlib
import logging
import os
import sqlite3
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from hermes_state_library_extract import RESULT_TOOL_NAMES, TOOL_NAMES, Occurrence, extract_message

logger = logging.getLogger(__name__)

FORMAT_VERSION = 1
CATCH_UP_BUDGET_S = 2.0
SCAN_CHUNK_ROWS = 400
LIVE_CHECK_BATCH = 400
KINDS = ("link", "media", "file")

_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
_ONE_MICROSECOND = timedelta(microseconds=1)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('link', 'media', 'file')),
    locator TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT NOT NULL,
    mime TEXT,
    ts_us INTEGER NOT NULL,
    order_us INTEGER NOT NULL UNIQUE,
    session_id TEXT NOT NULL,
    message_id INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_items_kind_order ON items(kind, order_us DESC);
"""

_SCAN_SQL = (
    "SELECT rowid, session_id, role, content, tool_calls, tool_name, timestamp FROM messages "
    "WHERE rowid > ? AND (active = 1 OR compacted = 1) AND _compressed_summary = 0 "
    f"AND (role IN ('user', 'assistant') OR tool_name IN ({','.join('?' * len(RESULT_TOOL_NAMES))})) "
    "ORDER BY rowid LIMIT ?")

_UPSERT_SQL = (
    "INSERT INTO items (id, kind, locator, title, subtitle, mime, ts_us, order_us, session_id, message_id) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
    "title = excluded.title, subtitle = excluded.subtitle, mime = excluded.mime, ts_us = excluded.ts_us, "
    "order_us = excluded.order_us, session_id = excluded.session_id, message_id = excluded.message_id")

_ITEM_COLUMNS = "id, kind, locator, title, subtitle, mime, order_us, session_id, message_id"

_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


@dataclass(frozen=True, slots=True)
class IndexedItem:
    id: str
    kind: str
    locator: str
    title: str
    subtitle: str
    mime: str | None
    order_us: int
    session_id: str
    message_id: int

    @property
    def occurred_at(self) -> str:
        return (_EPOCH + timedelta(microseconds=self.order_us)).isoformat()


def item_id(kind: str, locator: str) -> str:
    return hashlib.sha256(f"{kind}\x00{locator}".encode()).hexdigest()[:32]


def parse_cursor(value: str) -> int:
    moment = datetime.fromisoformat(value.strip())
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    return (moment - _EPOCH) // _ONE_MICROSECOND


def _path_lock(path: Path) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(str(path), threading.Lock())


class LibraryIndex:

    def __init__(self, home: Path | str):
        self.home = Path(home)
        self.path = self.home / "cache" / "library" / "index.sqlite3"

    @contextlib.contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path, timeout=10.0, isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            with contextlib.suppress(OSError):
                os.chmod(self.path, 0o600)
            self._ensure_schema(conn)
            yield conn
        finally:
            conn.close()

    def _ensure_schema(self, conn: sqlite3.Connection) -> None:
        if conn.execute("PRAGMA user_version").fetchone()[0] == FORMAT_VERSION:
            return
        conn.executescript("DROP TABLE IF EXISTS items; DROP TABLE IF EXISTS meta;")
        conn.executescript(_SCHEMA)
        conn.execute(f"PRAGMA user_version = {FORMAT_VERSION}")

    @staticmethod
    def _meta(conn: sqlite3.Connection, key: str) -> str | None:
        row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return None if row is None else row[0]

    @staticmethod
    def _set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
        conn.execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value))

    def refresh(self, db, *, budget_s: float = CATCH_UP_BUDGET_S) -> bool:
        deadline = time.monotonic() + budget_s
        with _path_lock(self.path), self._connect() as conn:
            instance = str(db.get_meta("store_instance_id") or "")
            with db._read_ctx() as source:
                high = source.execute("SELECT COALESCE(MAX(rowid), 0) FROM messages").fetchone()[0]
            watermark = int(self._meta(conn, "watermark") or 0)
            if self._meta(conn, "instance") != instance or watermark > high:
                conn.execute("BEGIN IMMEDIATE")
                conn.execute("DELETE FROM items")
                self._set_meta(conn, "instance", instance)
                self._set_meta(conn, "watermark", "0")
                conn.execute("COMMIT")
                watermark = 0
            while watermark < high:
                with db._read_ctx() as source:
                    rows = source.execute(
                        _SCAN_SQL, (watermark, *sorted(RESULT_TOOL_NAMES), SCAN_CHUNK_ROWS)).fetchall()
                reached = rows[-1][0] if len(rows) == SCAN_CHUNK_ROWS else high
                conn.execute("BEGIN IMMEDIATE")
                try:
                    for row in rows:
                        self._index_row(conn, row)
                    watermark = max(watermark, reached)
                    self._set_meta(conn, "watermark", str(watermark))
                    conn.execute("COMMIT")
                except BaseException:
                    conn.execute("ROLLBACK")
                    raise
                if watermark < high and time.monotonic() >= deadline:
                    return False
            return True

    def _index_row(self, conn: sqlite3.Connection, row) -> None:
        message_id, session_id, role, content, tool_calls, tool_name, timestamp = row
        from hermes_state import SessionDB
        from hermes_state_messages import _parse_tool_calls
        calls = _parse_tool_calls(tool_calls) if _mentions_tracked_tool(tool_calls) else None
        if role == "assistant" and not content and not calls:
            return
        decoded = SessionDB._decode_content(content)
        ts_us = int(float(timestamp or 0) * 1_000_000)
        for occurrence in extract_message(role, decoded, calls, tool_name):
            self._upsert(conn, occurrence, session_id, message_id, ts_us)

    @staticmethod
    def _upsert(conn: sqlite3.Connection, occurrence: Occurrence, session_id: str, message_id: int, ts_us: int) -> None:
        key = item_id(occurrence.kind, occurrence.locator)
        existing = conn.execute("SELECT ts_us, order_us FROM items WHERE id = ?", (key,)).fetchone()
        if existing is not None and ts_us < existing[0]:
            return
        order_us = existing[1] if existing is not None and ts_us == existing[0] else ts_us
        while conn.execute("SELECT 1 FROM items WHERE order_us = ? AND id != ?", (order_us, key)).fetchone():
            order_us += 1
        conn.execute(_UPSERT_SQL, (
            key, occurrence.kind, occurrence.locator, occurrence.title, occurrence.subtitle, occurrence.mime,
            ts_us, order_us, session_id, message_id))

    @staticmethod
    def live_message_ids(db, ids: list[int]) -> set[int]:
        live: set[int] = set()
        with db._read_ctx() as source:
            for start in range(0, len(ids), LIVE_CHECK_BATCH):
                batch = ids[start:start + LIVE_CHECK_BATCH]
                live.update(row[0] for row in source.execute(
                    f"SELECT id FROM messages WHERE id IN ({','.join('?' * len(batch))}) "
                    "AND (active = 1 OR compacted = 1)", batch))
        return live

    def page(self, db, *, kind: str | None, limit: int, before_us: int | None) -> tuple[list[IndexedItem], bool]:
        collected: list[IndexedItem] = []
        cursor = before_us if before_us is not None else 1 << 62
        batch = max(limit * 2, 50)
        where, args = ("kind = ? AND ", [kind]) if kind else ("", [])
        with self._connect() as conn:
            while len(collected) <= limit:
                rows = conn.execute(
                    f"SELECT {_ITEM_COLUMNS} FROM items WHERE {where}order_us < ? ORDER BY order_us DESC LIMIT ?",
                    (*args, cursor, batch)).fetchall()
                if not rows:
                    break
                live = self.live_message_ids(db, [row[8] for row in rows])
                collected.extend(IndexedItem(*row) for row in rows if row[8] in live)
                if len(rows) < batch:
                    break
                cursor = rows[-1][6]
        return collected[:limit], len(collected) > limit

    def lookup(self, key: str) -> IndexedItem | None:
        if not self.path.is_file():
            return None
        with self._connect() as conn:
            row = conn.execute(f"SELECT {_ITEM_COLUMNS} FROM items WHERE id = ?", (key,)).fetchone()
        return None if row is None else IndexedItem(*row)


def _mentions_tracked_tool(tool_calls) -> bool:
    return isinstance(tool_calls, str) and any(f'"{name}"' in tool_calls for name in TOOL_NAMES)
