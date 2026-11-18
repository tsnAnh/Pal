from __future__ import annotations

import contextlib
import json
import os
import re
import sqlite3
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

from gateway.device_registry import install_root

DB_NAME = "connector_setup_progress.db"
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$")
MAX_COMPLETED = 32
DEVICES = frozenset({"mac", "iphone", "ipad"})

SCHEMA = """
CREATE TABLE IF NOT EXISTS progress (
    connector TEXT NOT NULL,
    bot TEXT NOT NULL,
    step_id TEXT NOT NULL,
    completed TEXT NOT NULL,
    device TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (connector, bot)
);
"""


class InvalidProgress(ValueError):
    pass


@dataclass(frozen=True)
class SetupProgressRecord:
    connector: str
    bot: str | None
    step_id: str
    completed: tuple[str, ...]
    device: str
    updated_at: float


def valid_id(value: str) -> bool:
    return bool(ID_PATTERN.fullmatch(value))


class SetupProgressStore:
    def __init__(self, home, clock: Callable[[], float] = time.time):
        self._path = Path(install_root(home)) / DB_NAME
        self._clock = clock

    def _open(self) -> sqlite3.Connection:
        from hermes_cli.sqlite_util import open_db
        conn = open_db(self._path, db_label=DB_NAME, busy_timeout_ms=10_000,
                       initialize=lambda c: c.executescript(SCHEMA))
        with contextlib.suppress(OSError):
            os.chmod(self._path, 0o600)
        return conn

    @contextlib.contextmanager
    def _write(self) -> Iterator[sqlite3.Connection]:
        from hermes_cli.sqlite_util import transaction
        with transaction(self._open(), immediate=True) as conn:
            yield conn

    def get(self, connector: str | None = None, bot: str | None = None) -> list[SetupProgressRecord]:
        clauses, args = [], []
        if connector is not None:
            clauses.append("connector = ?")
            args.append(connector)
        if bot is not None:
            clauses.append("bot = ?")
            args.append(bot)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        conn = self._open()
        try:
            rows = conn.execute(f"SELECT * FROM progress{where} ORDER BY updated_at DESC, connector, bot", args).fetchall()
        finally:
            conn.close()
        return [_record(row) for row in rows]

    def set(self, connector: str, bot: str | None, step_id: str, completed: list[str], device: str) -> SetupProgressRecord:
        ids = [connector, step_id, *completed] + ([bot] if bot else [])
        if not all(valid_id(i) for i in ids) or len(completed) > MAX_COMPLETED or device not in DEVICES:
            raise InvalidProgress("Setup progress holds step ids only.")
        unique = sorted(set(completed))
        now = self._clock()
        with self._write() as conn:
            conn.execute(
                "INSERT INTO progress (connector, bot, step_id, completed, device, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(connector, bot) DO UPDATE SET step_id = excluded.step_id, completed = excluded.completed, "
                "device = excluded.device, updated_at = excluded.updated_at",
                (connector, bot or "", step_id, json.dumps(unique), device, now),
            )
        return SetupProgressRecord(connector, bot or None, step_id, tuple(unique), device, now)

    def clear(self, connector: str, bot: str | None) -> bool:
        if not valid_id(connector) or (bot and not valid_id(bot)):
            raise InvalidProgress("Setup progress holds step ids only.")
        with self._write() as conn:
            return conn.execute("DELETE FROM progress WHERE connector = ? AND bot = ?", (connector, bot or "")).rowcount > 0


def _record(row: sqlite3.Row) -> SetupProgressRecord:
    try:
        completed = tuple(str(i) for i in json.loads(row["completed"]))
    except (TypeError, ValueError):
        completed = ()
    return SetupProgressRecord(row["connector"], row["bot"] or None, row["step_id"], completed, row["device"], row["updated_at"])


def build_store(home=None) -> SetupProgressStore:
    from hermes_constants import get_hermes_home
    return SetupProgressStore(home or get_hermes_home())
