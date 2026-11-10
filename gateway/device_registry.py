from __future__ import annotations

import contextlib
import hashlib
import os
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path

DB_NAME = "devices.db"
GRANT_LIFETIME_SECONDS = 30 * 24 * 60 * 60
PUSH_CLAIM_RETENTION_SECONDS = 24 * 60 * 60
REVOKED_CACHE_SECONDS = 2.0

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    label TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    os TEXT NOT NULL DEFAULT '',
    app_version TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL,
    last_seen_at REAL NOT NULL,
    push_token TEXT,
    push_environment TEXT,
    push_bundle_id TEXT,
    push_registered_at REAL
);
CREATE INDEX IF NOT EXISTS devices_push_token ON devices(push_token) WHERE push_token IS NOT NULL;
CREATE TABLE IF NOT EXISTS device_grants (
    refresh_digest TEXT PRIMARY KEY,
    access_digest TEXT NOT NULL,
    device_id TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS device_grants_device ON device_grants(device_id);
CREATE TABLE IF NOT EXISTS revoked_tokens (
    token_digest TEXT PRIMARY KEY,
    revoked_at REAL NOT NULL,
    expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS push_claims (
    claim_key TEXT PRIMARY KEY,
    claimed_at REAL NOT NULL
);
"""


@dataclass(frozen=True, slots=True)
class DeviceRecord:
    device_id: str
    kind: str
    label: str
    model: str
    os: str
    app_version: str
    last_seen_at: float
    has_push_token: bool


@dataclass(frozen=True, slots=True)
class PushTarget:
    device_id: str
    token: str
    environment: str
    bundle_id: str


@dataclass(frozen=True, slots=True)
class Forgotten:
    existed: bool
    push_removed: bool
    grants_revoked: int


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def install_root(home) -> Path:
    from hermes_constants import get_default_hermes_root
    candidate = Path(str(home)) if home else None
    return get_default_hermes_root(home=candidate if candidate is not None and candidate.is_absolute() else None)


def _db_path(root) -> Path:
    return Path(root) / DB_NAME


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def _open(root) -> sqlite3.Connection:
    from hermes_cli.sqlite_util import open_db
    path = _db_path(root)
    conn = open_db(path, db_label="devices.db", busy_timeout_ms=10_000, initialize=_initialize)
    with contextlib.suppress(OSError):
        os.chmod(path, 0o600)
    return conn


@contextlib.contextmanager
def _write(root):
    from hermes_cli.sqlite_util import transaction
    with transaction(_open(root), immediate=True) as conn:
        yield conn


@contextlib.contextmanager
def _read(root):
    conn = _open(root)
    try:
        yield conn
    finally:
        conn.close()


def _record(row: sqlite3.Row) -> DeviceRecord:
    return DeviceRecord(device_id=row["device_id"], kind=row["kind"], label=row["label"], model=row["model"],
                        os=row["os"], app_version=row["app_version"], last_seen_at=row["last_seen_at"],
                        has_push_token=row["push_token"] is not None)


def record_hello(root, *, device_id: str, kind: str, label: str, model: str, os_name: str, app_version: str,
                 now: float) -> None:
    with _write(root) as conn:
        conn.execute(
            "INSERT INTO devices (device_id, kind, label, model, os, app_version, created_at, last_seen_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(device_id) DO UPDATE SET kind = excluded.kind, label = excluded.label, "
            "model = excluded.model, os = excluded.os, app_version = excluded.app_version, "
            "last_seen_at = MAX(last_seen_at, excluded.last_seen_at)",
            (device_id, kind, label, model, os_name, app_version, now, now))


def touch(root, device_id: str, now: float) -> None:
    with _write(root) as conn:
        conn.execute("UPDATE devices SET last_seen_at = MAX(last_seen_at, ?) WHERE device_id = ?", (now, device_id))


def list_devices(root) -> list[DeviceRecord]:
    with _read(root) as conn:
        rows = conn.execute("SELECT * FROM devices ORDER BY last_seen_at DESC, device_id").fetchall()
    return [_record(row) for row in rows]


def get_device(root, device_id: str) -> DeviceRecord | None:
    with _read(root) as conn:
        row = conn.execute("SELECT * FROM devices WHERE device_id = ?", (device_id,)).fetchone()
    return _record(row) if row is not None else None


def set_push_token(root, device_id: str, token: str, environment: str, bundle_id: str, now: float) -> bool:
    with _write(root) as conn:
        conn.execute("UPDATE devices SET push_token = NULL, push_environment = NULL, push_bundle_id = NULL, "
                     "push_registered_at = NULL WHERE push_token = ? AND device_id != ?", (token, device_id))
        updated = conn.execute(
            "UPDATE devices SET push_token = ?, push_environment = ?, push_bundle_id = ?, push_registered_at = ? "
            "WHERE device_id = ?", (token, environment, bundle_id, now, device_id))
        return updated.rowcount == 1


def clear_push_token(root, device_id: str) -> bool:
    with _write(root) as conn:
        cleared = conn.execute(
            "UPDATE devices SET push_token = NULL, push_environment = NULL, push_bundle_id = NULL, "
            "push_registered_at = NULL WHERE device_id = ? AND push_token IS NOT NULL", (device_id,))
        return cleared.rowcount == 1


def drop_push_token(root, token: str) -> bool:
    with _write(root) as conn:
        dropped = conn.execute(
            "UPDATE devices SET push_token = NULL, push_environment = NULL, push_bundle_id = NULL, "
            "push_registered_at = NULL WHERE push_token = ?", (token,))
        return dropped.rowcount > 0


def push_targets(root) -> list[PushTarget]:
    with _read(root) as conn:
        rows = conn.execute(
            "SELECT device_id, push_token, push_environment, push_bundle_id FROM devices "
            "WHERE kind IN ('ios', 'mac') AND push_token IS NOT NULL ORDER BY device_id").fetchall()
    return [PushTarget(row["device_id"], row["push_token"], row["push_environment"], row["push_bundle_id"])
            for row in rows]


def bind_grant(root, *, device_id: str, access_token: str, refresh_token: str, provider: str, now: float) -> None:
    with _write(root) as conn:
        conn.execute(
            "INSERT INTO device_grants (refresh_digest, access_digest, device_id, provider, created_at, expires_at) "
            "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(refresh_digest) DO UPDATE SET access_digest = excluded.access_digest, "
            "device_id = excluded.device_id, expires_at = excluded.expires_at",
            (digest(refresh_token), digest(access_token), device_id, provider, now, now + GRANT_LIFETIME_SECONDS))
        conn.execute("DELETE FROM device_grants WHERE expires_at <= ?", (now,))


def rotate_grant(root, *, old_refresh_token: str, access_token: str, refresh_token: str, now: float) -> str | None:
    with _write(root) as conn:
        found = conn.execute("SELECT device_id, provider FROM device_grants WHERE refresh_digest = ?",
                             (digest(old_refresh_token),)).fetchone()
        if found is None:
            return None
        conn.execute("DELETE FROM device_grants WHERE refresh_digest = ?", (digest(old_refresh_token),))
        conn.execute(
            "INSERT OR REPLACE INTO device_grants (refresh_digest, access_digest, device_id, provider, created_at, "
            "expires_at) VALUES (?, ?, ?, ?, ?, ?)",
            (digest(refresh_token), digest(access_token), found["device_id"], found["provider"], now,
             now + GRANT_LIFETIME_SECONDS))
        return found["device_id"]


_revoked_cache: dict[str, tuple[float, frozenset[str]]] = {}
_revoked_lock = threading.Lock()


def _revoked_digests(root, now: float) -> frozenset[str]:
    if not _db_path(root).exists():
        return frozenset()
    with _read(root) as conn:
        rows = conn.execute("SELECT token_digest FROM revoked_tokens WHERE expires_at > ?", (now,)).fetchall()
    return frozenset(row["token_digest"] for row in rows)


def is_revoked(root, token: str) -> bool:
    key = str(Path(root))
    with _revoked_lock:
        cached = _revoked_cache.get(key)
        if cached is not None and time.monotonic() - cached[0] < REVOKED_CACHE_SECONDS:
            return digest(token) in cached[1]
    digests = _revoked_digests(root, time.time())
    with _revoked_lock:
        _revoked_cache[key] = (time.monotonic(), digests)
    return digest(token) in digests


def forget(root, device_id: str, now: float) -> Forgotten:
    with _write(root) as conn:
        row = conn.execute("SELECT push_token FROM devices WHERE device_id = ?", (device_id,)).fetchone()
        grants = conn.execute("SELECT refresh_digest, access_digest FROM device_grants WHERE device_id = ?",
                              (device_id,)).fetchall()
        conn.executemany(
            "INSERT OR REPLACE INTO revoked_tokens (token_digest, revoked_at, expires_at) VALUES (?, ?, ?)",
            [(token_digest, now, now + GRANT_LIFETIME_SECONDS)
             for grant in grants for token_digest in (grant["refresh_digest"], grant["access_digest"])])
        conn.execute("DELETE FROM device_grants WHERE device_id = ?", (device_id,))
        conn.execute("DELETE FROM devices WHERE device_id = ?", (device_id,))
        conn.execute("DELETE FROM revoked_tokens WHERE expires_at <= ?", (now,))
    with _revoked_lock:
        _revoked_cache.pop(str(Path(root)), None)
    return Forgotten(existed=row is not None, push_removed=row is not None and row["push_token"] is not None,
                     grants_revoked=len(grants))


def claim_push(root, claim_key: str, now: float) -> bool:
    with _write(root) as conn:
        conn.execute("DELETE FROM push_claims WHERE claimed_at <= ?", (now - PUSH_CLAIM_RETENTION_SECONDS,))
        claimed = conn.execute("INSERT OR IGNORE INTO push_claims (claim_key, claimed_at) VALUES (?, ?)",
                               (claim_key, now))
        return claimed.rowcount == 1
