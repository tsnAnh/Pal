from __future__ import annotations

import logging
import sqlite3
import statistics
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger("gateway.send_trace")

DB_NAME = "send_trace.db"
RETENTION_SECONDS = 7 * 24 * 60 * 60
MAX_ROWS = 5000
MAX_FIELD = 64
DEFAULT_HOURS = 24
MAX_HOURS = RETENTION_SECONDS // 3600
STATUSES = ("steered", "queued", "turn", "untouched")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,
    admission TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT '',
    why TEXT NOT NULL DEFAULT '',
    ms INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
"""


def _db_path(root: Path | None) -> Path:
    if root is None:
        from hermes_constants import get_default_hermes_root
        root = get_default_hermes_root()
    return Path(root) / DB_NAME


def open_readonly(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def record(kind: str, admission: str, status: str, why: str, ms: float, *, root: Path | None = None,
           now: float | None = None) -> None:
    from hermes_cli.sqlite_util import open_db
    ts = time.time() if now is None else now
    try:
        conn = open_db(_db_path(root), db_label=f"{DB_NAME} (send trace)", busy_timeout_ms=2_000,
                       initialize=lambda c: c.executescript(_SCHEMA))
        try:
            with conn:
                conn.execute("INSERT INTO events (ts, kind, admission, status, why, ms) VALUES (?, ?, ?, ?, ?, ?)",
                             (ts, kind, str(admission)[:MAX_FIELD], str(status)[:MAX_FIELD], str(why)[:MAX_FIELD],
                              int(ms)))
                conn.execute("DELETE FROM events WHERE ts < ?", (ts - RETENTION_SECONDS,))
                conn.execute("DELETE FROM events WHERE id <= (SELECT id FROM events ORDER BY id DESC "
                             "LIMIT 1 OFFSET ?)", (MAX_ROWS,))
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as exc:
        logger.warning("send_trace ledger write failed (%s)", type(exc).__name__)


def admitted(admission_id: str, status: Optional[str], why: str, absorb_ms: float, *,
             root: Path | None = None) -> None:
    status = status or "untouched"
    logger.warning("send_trace admitted admission=%s status=%s why=%s absorb_ms=%d",
                   admission_id, status, why, absorb_ms)
    record("admitted", admission_id, status, why, absorb_ms, root=root)


def steer_drained(admission_id: str, wait_ms: float, *, root: Path | None = None) -> None:
    logger.warning("send_trace steer_drained admission=%s wait_ms=%d", admission_id, wait_ms)
    record("drained", admission_id, "", "", wait_ms, root=root)


def _spread(values: list[int]) -> Optional[dict]:
    if not values:
        return None
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def summary(*, hours: int = DEFAULT_HOURS, root: Path | None = None, now: float | None = None) -> Optional[dict]:
    hours = max(1, min(int(hours), MAX_HOURS))
    path = _db_path(root)
    if not path.is_file():
        return None
    since = (time.time() if now is None else now) - hours * 3600
    conn = open_readonly(path)
    try:
        rows = conn.execute("SELECT kind, status, why, ms FROM events WHERE ts >= ?", (since,)).fetchall()
    finally:
        conn.close()
    admitted_rows = [row for row in rows if row["kind"] == "admitted"]
    by_status = dict.fromkeys(STATUSES, 0)
    by_why: dict[str, int] = {}
    for row in admitted_rows:
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1
        by_why[row["why"]] = by_why.get(row["why"], 0) + 1
    drained = [row["ms"] for row in rows if row["kind"] == "drained"]
    return {
        "window_hours": hours,
        "admitted": len(admitted_rows),
        "by_status": by_status,
        "by_why": dict(sorted(by_why.items(), key=lambda item: (-item[1], item[0]))),
        "absorb_ms": _spread([row["ms"] for row in admitted_rows]),
        "steer_drained": len(drained),
        "wait_ms": _spread(drained),
    }
