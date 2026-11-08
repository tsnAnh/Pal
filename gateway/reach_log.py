from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from gateway.reach_policy import BUDGET_WINDOW_SECONDS, LogView, Verdict

RETENTION_SECONDS = 90 * 24 * 60 * 60
EXPIRY_SECONDS = 24 * 60 * 60
MAINTENANCE_INTERVAL_SECONDS = 60 * 60
TERMINAL_OUTCOMES = frozenset({"acted", "dismissed", "expired"})
PENDING_ALERT_STATUSES = ("routing", "deferred")

_recovered: set[tuple[int, str]] = set()
_recovered_lock = threading.Lock()
_last_maintenance: dict[str, float] = {}


@dataclass(frozen=True, slots=True)
class Claim:
    row: dict
    created: bool
    verdict: Verdict | None


def _db_path(home) -> Path:
    return Path(home).resolve() / "state.db"


def _initialize(conn: sqlite3.Connection) -> None:
    from hermes_state_common import REACH_OFFERS_SQL
    conn.executescript(REACH_OFFERS_SQL)


def _connect(home) -> sqlite3.Connection:
    from hermes_cli.sqlite_util import open_db
    return open_db(_db_path(home), db_label="state.db (reach_offers)", busy_timeout_ms=10_000,
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


def _row(conn: sqlite3.Connection, offer_id: str) -> dict | None:
    found = conn.execute("SELECT * FROM reach_offers WHERE offer_id = ?", (offer_id,)).fetchone()
    return dict(found) if found is not None else None


def _row_by_key(conn: sqlite3.Connection, producer_key: str) -> dict | None:
    found = conn.execute("SELECT * FROM reach_offers WHERE producer_key = ?", (producer_key,)).fetchone()
    return dict(found) if found is not None else None


def view_of(conn: sqlite3.Connection, now: float, *, excluding: str | None = None) -> LogView:
    found = conn.execute(
        "SELECT COUNT(*), MAX(COALESCE(alerted_at, created_at)) FROM reach_offers "
        "WHERE consent = 'initiated' AND offer_id != ? AND created_at >= ? "
        "AND (alerted_at IS NOT NULL OR status IN ('routing', 'deferred'))",
        (excluding or "", now - BUDGET_WINDOW_SECONDS)).fetchone()
    return LogView(alerted_last_24h=int(found[0] or 0), last_alert_at=found[1])


def _status_for(verdict: Verdict) -> str:
    if verdict.alert:
        return "routing"
    if verdict.defer_until is not None:
        return "deferred"
    return "landed_silent" if verdict.land else "suppressed"


def claim(home, *, producer_key: str, domain: str, kind: str, consent: str, title: str,
          judge: Callable[[LogView], Verdict], now: float) -> Claim:
    recover_once(home)
    offer_id = uuid.uuid4().hex
    with _immediate(home) as conn:
        inserted = conn.execute(
            "INSERT OR IGNORE INTO reach_offers (offer_id, producer_key, domain, kind, consent, title, "
            "created_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, 'routing')",
            (offer_id, producer_key, domain, kind, consent, title, now)).rowcount
        if inserted == 0:
            return Claim(_row_by_key(conn, producer_key), False, None)
        verdict = judge(view_of(conn, now, excluding=offer_id))
        conn.execute(
            "UPDATE reach_offers SET status = ?, reason = ?, not_before = ? WHERE offer_id = ?",
            (_status_for(verdict), verdict.reason, verdict.defer_until, offer_id))
        return Claim(_row(conn, offer_id), True, verdict)


def claim_deferred(home, offer_id: str, *, judge: Callable[[LogView], Verdict], now: float) -> Claim | None:
    with _immediate(home) as conn:
        row = _row(conn, offer_id)
        if row is None or row["status"] != "deferred" or row["outcome"] is not None:
            return None
        verdict = judge(view_of(conn, now, excluding=offer_id))
        status = _status_for(verdict)
        conn.execute("UPDATE reach_offers SET status = ?, reason = ?, not_before = ? WHERE offer_id = ?",
                     (status, verdict.reason, verdict.defer_until, offer_id))
        return Claim(_row(conn, offer_id), False, verdict)


def append_attempt(home, offer_id: str, attempt: dict) -> None:
    with _immediate(home) as conn:
        found = conn.execute("SELECT attempts_json FROM reach_offers WHERE offer_id = ?", (offer_id,)).fetchone()
        if found is None:
            return
        attempts = json.loads(found[0] or "[]")
        attempts.append(attempt)
        conn.execute("UPDATE reach_offers SET attempts_json = ? WHERE offer_id = ?",
                     (json.dumps(attempts, separators=(",", ":")), offer_id))


def finalize(home, offer_id: str, *, status: str, reason: str, route: dict | None = None,
             alerted_at: float | None = None) -> None:
    with _immediate(home) as conn:
        conn.execute(
            "UPDATE reach_offers SET status = ?, reason = ?, route_json = ?, alerted_at = ? "
            "WHERE offer_id = ? AND status = 'routing'",
            (status, reason, json.dumps(route, separators=(",", ":")) if route is not None else None,
             alerted_at, offer_id))


def record_outcome(home, offer_id: str, outcome: str, device_id: str | None, now: float) -> tuple[dict | None, bool]:
    with _immediate(home) as conn:
        row = _row(conn, offer_id)
        if row is None:
            return None, False
        current = row["outcome"]
        if current in TERMINAL_OUTCOMES or (current == "shown" and outcome == "shown"):
            return row, False
        conn.execute("UPDATE reach_offers SET outcome = ?, outcome_at = ?, outcome_device = ? WHERE offer_id = ?",
                     (outcome, now, device_id, offer_id))
        return _row(conn, offer_id), True


def get(home, offer_id: str) -> dict | None:
    conn = _connect(home)
    try:
        return _row(conn, offer_id)
    finally:
        conn.close()


def due_deferred(home, now: float, limit: int = 20) -> list[dict]:
    conn = _connect(home)
    try:
        found = conn.execute(
            "SELECT * FROM reach_offers WHERE status = 'deferred' AND not_before <= ? AND outcome IS NULL "
            "ORDER BY not_before LIMIT ?", (now, limit)).fetchall()
        return [dict(row) for row in found]
    finally:
        conn.close()


def recover(home) -> int:
    with _immediate(home) as conn:
        return conn.execute(
            "UPDATE reach_offers SET status = 'unknown', reason = 'interrupted' WHERE status = 'routing'").rowcount


def recover_once(home) -> None:
    import os
    key = (os.getpid(), str(Path(home).resolve()))
    with _recovered_lock:
        if key in _recovered:
            return
        recover(home)
        _recovered.add(key)


def maintain(home, now: float) -> None:
    with _immediate(home) as conn:
        conn.execute(
            "UPDATE reach_offers SET outcome = 'expired', outcome_at = ? "
            "WHERE status = 'alerted' AND outcome IS NULL AND alerted_at < ?", (now, now - EXPIRY_SECONDS))
        conn.execute("DELETE FROM reach_offers WHERE created_at < ?", (now - RETENTION_SECONDS,))


def maintain_throttled(home, now: float) -> None:
    key = str(Path(home).resolve())
    with _recovered_lock:
        if now - _last_maintenance.get(key, 0.0) < MAINTENANCE_INTERVAL_SECONDS:
            return
        _last_maintenance[key] = now
    maintain(home, now)


def latest_inbound_chat(home, since: float, excluded_sources: frozenset[str]) -> dict | None:
    conn = _connect(home)
    try:
        sessions = conn.execute(
            "SELECT id, source, chat_id, thread_id, origin_json FROM sessions "
            "WHERE chat_id IS NOT NULL AND chat_id != '' AND (ended_at IS NULL OR ended_at >= ?)",
            (since,)).fetchall()
        best = None
        for session in sessions:
            if session["source"] in excluded_sources:
                continue
            stamp = conn.execute(
                "SELECT MAX(timestamp) FROM messages WHERE session_id = ? AND role = 'user' AND timestamp >= ?",
                (session["id"], since)).fetchone()[0]
            if stamp is not None and (best is None or stamp > best["at"]):
                best = {"at": stamp, "platform": session["source"], "chat_id": session["chat_id"],
                        "thread_id": session["thread_id"] or None, "origin_json": session["origin_json"]}
        return best
    finally:
        conn.close()


def list_offers(home, *, since: float | None = None, limit: int = 500) -> list[dict]:
    conn = _connect(home)
    try:
        found = conn.execute(
            "SELECT * FROM reach_offers WHERE created_at >= ? ORDER BY created_at DESC LIMIT ?",
            (since or 0.0, limit)).fetchall()
        return [dict(row) for row in found]
    finally:
        conn.close()
