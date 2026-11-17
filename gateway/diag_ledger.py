from __future__ import annotations

import logging
import sqlite3
import time
from dataclasses import asdict, dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

DB_NAME = "diag_faults.db"
RETENTION_SECONDS = 7 * 24 * 60 * 60
MAX_ROWS = 5000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS faults (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    trace TEXT NOT NULL,
    method TEXT NOT NULL DEFAULT '',
    code INTEGER,
    reason TEXT NOT NULL DEFAULT '',
    device_kind TEXT NOT NULL DEFAULT '',
    device_name TEXT NOT NULL DEFAULT '',
    app_build TEXT NOT NULL DEFAULT '',
    gateway_version TEXT NOT NULL DEFAULT '',
    params_shape TEXT NOT NULL DEFAULT '',
    scope TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'gateway'
);
CREATE INDEX IF NOT EXISTS faults_ts ON faults (ts);
"""


@dataclass(frozen=True, slots=True)
class Fault:
    ts: float
    trace: str
    method: str
    code: int | None
    reason: str
    device_kind: str = ""
    device_name: str = ""
    app_build: str = ""
    gateway_version: str = ""
    params_shape: str = ""
    scope: str = ""
    source: str = "gateway"


def _db_path(root: Path | None) -> Path:
    if root is None:
        from hermes_constants import get_default_hermes_root
        root = get_default_hermes_root()
    return Path(root) / DB_NAME


def _connect(root: Path | None) -> sqlite3.Connection:
    from hermes_cli.sqlite_util import open_db
    return open_db(_db_path(root), db_label=f"{DB_NAME} (faults)", busy_timeout_ms=2_000,
                   initialize=lambda conn: conn.executescript(_SCHEMA))


def _type_name(value) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, (list, tuple)):
        return "array"
    return "null" if value is None else "other"


def params_shape(params) -> str:
    if not isinstance(params, dict):
        return ""
    return ",".join(f"{key}:{_type_name(params[key])}" for key in sorted(str(k) for k in params if isinstance(k, str)))


def record(fault: Fault, *, root: Path | None = None) -> None:
    try:
        conn = _connect(root)
        try:
            with conn:
                row = asdict(fault)
                conn.execute(f"INSERT INTO faults ({', '.join(row)}) VALUES ({', '.join('?' * len(row))})",
                             tuple(row.values()))
                conn.execute("DELETE FROM faults WHERE ts < ?", (fault.ts - RETENTION_SECONDS,))
                conn.execute("DELETE FROM faults WHERE id <= (SELECT id FROM faults ORDER BY id DESC "
                             "LIMIT 1 OFFSET ?)", (MAX_ROWS,))
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as exc:
        logger.warning("could not record a fault (%s)", type(exc).__name__)


def recent(*, minutes: int, limit: int, method: str | None = None, root: Path | None = None,
           now: float | None = None) -> list[dict]:
    since = (time.time() if now is None else now) - minutes * 60
    query = "SELECT * FROM faults WHERE ts >= ?"
    args: list = [since]
    if method:
        query += " AND method = ?"
        args.append(method)
    query += " ORDER BY ts DESC, id DESC LIMIT ?"
    args.append(limit)
    conn = _connect(root)
    try:
        rows = conn.execute(query, args).fetchall()
    finally:
        conn.close()
    return [{key: row[key] for key in row.keys() if key != "id"} for row in rows]
