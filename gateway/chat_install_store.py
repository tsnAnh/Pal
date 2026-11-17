from __future__ import annotations

import contextlib
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

from gateway.device_registry import install_root
from tui_gateway.chat_install import SetupKey, StaleRevision, setup_key
from tui_gateway.contracts.chat_provider import Binding, Installation, InstallationStatus, SetupState

DB_NAME = "chat_install.db"
SCHEMA_VERSION = 1
NONCE_TTL_SECONDS = 600.0
OUTBOX_RETENTION_SECONDS = 24 * 60 * 60

SCHEMA = """
CREATE TABLE IF NOT EXISTS setup_states (
    bot TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    workspace TEXT NOT NULL,
    revision INTEGER NOT NULL,
    installation_id TEXT,
    state_json TEXT NOT NULL,
    config_item_id TEXT,
    authorize_link TEXT,
    PRIMARY KEY (bot, provider_id, workspace)
);
CREATE TABLE IF NOT EXISTS outbox (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    bot TEXT NOT NULL,
    state_json TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS nonces (
    digest TEXT PRIMARY KEY,
    bot TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    workspace TEXT NOT NULL,
    expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS installations (
    id TEXT PRIMARY KEY,
    bot TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    workspace TEXT NOT NULL,
    installation_json TEXT NOT NULL,
    env_keys_json TEXT NOT NULL DEFAULT '[]',
    owner_id TEXT NOT NULL,
    welcome_sent_at REAL
);
CREATE INDEX IF NOT EXISTS installations_lookup ON installations(provider_id, workspace, bot);
CREATE TABLE IF NOT EXISTS bindings (
    installation_id TEXT NOT NULL,
    space_id TEXT NOT NULL,
    bot TEXT NOT NULL,
    live INTEGER NOT NULL,
    hello_requested INTEGER NOT NULL DEFAULT 0,
    hello_sent_at REAL,
    PRIMARY KEY (installation_id, space_id)
);
"""


@dataclass(frozen=True, slots=True)
class BindingRow:
    installation_id: str
    space_id: str
    bot: str
    live: bool
    hello_requested: bool
    hello_sent_at: float | None

    def wire(self) -> Binding:
        return Binding(bot=self.bot, space_id=self.space_id, installation_id=self.installation_id, live=self.live)


def _initialize(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    if conn.execute("PRAGMA user_version").fetchone()[0] < SCHEMA_VERSION:
        conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")


def digest(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


class ChatInstallStore:
    def __init__(self, home, clock: Callable[[], float] = time.time):
        self._path = Path(install_root(home)) / DB_NAME
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

    def _append(self, conn: sqlite3.Connection, state: SetupState) -> None:
        now = self._clock()
        conn.execute("INSERT INTO outbox (bot, state_json, created_at) VALUES (?, ?, ?)",
                     (state.bot, state.model_dump_json(), now))
        conn.execute("DELETE FROM outbox WHERE created_at < ?", (now - OUTBOX_RETENTION_SECONDS,))

    def load(self, key: SetupKey) -> SetupState | None:
        with self._read() as conn:
            row = conn.execute("SELECT state_json FROM setup_states WHERE bot=? AND provider_id=? AND workspace=?",
                               key).fetchone()
        return SetupState.model_validate_json(row["state_json"]) if row else None

    def save(self, state: SetupState, expected_revision: int) -> None:
        key = setup_key(state)
        with self._write() as conn:
            row = conn.execute("SELECT revision FROM setup_states WHERE bot=? AND provider_id=? AND workspace=?",
                               key).fetchone()
            if (row["revision"] if row else 0) != expected_revision:
                raise StaleRevision(key)
            conn.execute(
                "INSERT INTO setup_states (bot, provider_id, workspace, revision, installation_id, state_json) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(bot, provider_id, workspace) DO UPDATE SET "
                "revision=excluded.revision, installation_id=excluded.installation_id, state_json=excluded.state_json",
                (*key, state.revision, state.installation_id, state.model_dump_json()))
            self._append(conn, state)

    def _aux(self, column: str, key: SetupKey) -> str | None:
        with self._read() as conn:
            row = conn.execute(f"SELECT {column} FROM setup_states WHERE bot=? AND provider_id=? AND workspace=?",
                               key).fetchone()
        return row[column] if row else None

    def _set_aux(self, column: str, key: SetupKey, value: str) -> None:
        with self._write() as conn:
            conn.execute(f"UPDATE setup_states SET {column}=? WHERE bot=? AND provider_id=? AND workspace=?",
                         (value, *key))

    def config_item(self, key: SetupKey) -> str | None:
        return self._aux("config_item_id", key)

    def set_config_item(self, key: SetupKey, vault_item_id: str) -> None:
        self._set_aux("config_item_id", key, vault_item_id)

    def authorize_link(self, key: SetupKey) -> str | None:
        return self._aux("authorize_link", key)

    def set_authorize_link(self, key: SetupKey, link: str) -> None:
        self._set_aux("authorize_link", key, link)

    def events_after(self, seq: int) -> list[tuple[int, SetupState]]:
        if not self._path.exists():
            return []
        with self._read() as conn:
            rows = conn.execute("SELECT seq, state_json FROM outbox WHERE seq > ? ORDER BY seq", (seq,)).fetchall()
        return [(row["seq"], SetupState.model_validate_json(row["state_json"])) for row in rows]

    def latest_seq(self) -> int:
        if not self._path.exists():
            return 0
        with self._read() as conn:
            row = conn.execute("SELECT MAX(seq) AS seq FROM outbox").fetchone()
        return row["seq"] or 0

    def issue_nonce(self, key: SetupKey, ttl: float = NONCE_TTL_SECONDS) -> str:
        raw = secrets.token_urlsafe(32)
        with self._write() as conn:
            conn.execute("DELETE FROM nonces WHERE bot=? AND provider_id=? AND workspace=?", key)
            conn.execute("DELETE FROM nonces WHERE expires_at <= ?", (self._clock(),))
            conn.execute("INSERT INTO nonces (digest, bot, provider_id, workspace, expires_at) VALUES (?, ?, ?, ?, ?)",
                         (digest(raw), *key, self._clock() + ttl))
        return raw

    def consume_nonce(self, raw: str, now: float | None = None) -> SetupKey | None:
        wanted = digest(raw)
        now = self._clock() if now is None else now
        with self._write() as conn:
            row = conn.execute("SELECT digest, bot, provider_id, workspace, expires_at FROM nonces WHERE digest=?",
                               (wanted,)).fetchone()
            if row is None or not hmac.compare_digest(row["digest"], wanted):
                return None
            conn.execute("DELETE FROM nonces WHERE digest=?", (wanted,))
        if row["expires_at"] <= now:
            return None
        return row["bot"], row["provider_id"], row["workspace"]

    def save_installation(self, installation: Installation, env_keys: list[str], owner_id: str) -> None:
        with self._write() as conn:
            conn.execute(
                "INSERT INTO installations (id, bot, provider_id, workspace, installation_json, env_keys_json, owner_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET installation_json=excluded.installation_json, "
                "env_keys_json=excluded.env_keys_json, owner_id=excluded.owner_id",
                (installation.id, installation.bot, installation.provider_id, installation.workspace_id,
                 installation.model_dump_json(), json.dumps(sorted(env_keys)), owner_id))

    def set_owner(self, installation_id: str, owner_id: str) -> None:
        with self._write() as conn:
            conn.execute("UPDATE installations SET owner_id=? WHERE id=?", (owner_id, installation_id))

    def owner_id(self, installation_id: str) -> str | None:
        with self._read() as conn:
            row = conn.execute("SELECT owner_id FROM installations WHERE id=?", (installation_id,)).fetchone()
        return row["owner_id"] if row else None

    def installation(self, installation_id: str) -> Installation | None:
        with self._read() as conn:
            row = conn.execute("SELECT installation_json FROM installations WHERE id=?", (installation_id,)).fetchone()
        return Installation.model_validate_json(row["installation_json"]) if row else None

    def installation_for_workspace(self, provider_id: str, workspace_id: str, bot: str) -> Installation | None:
        with self._read() as conn:
            rows = conn.execute("SELECT installation_json FROM installations WHERE provider_id=? AND workspace=? AND bot=?",
                                (provider_id, workspace_id, bot)).fetchall()
        found = [Installation.model_validate_json(row["installation_json"]) for row in rows]
        active = [item for item in found if item.status is InstallationStatus.active]
        return active[0] if active else None

    def env_keys(self, installation_id: str) -> list[str]:
        with self._read() as conn:
            row = conn.execute("SELECT env_keys_json FROM installations WHERE id=?", (installation_id,)).fetchone()
        return json.loads(row["env_keys_json"]) if row else []

    def mark_revoked(self, installation_id: str, now: float) -> None:
        with self._write() as conn:
            row = conn.execute("SELECT installation_json FROM installations WHERE id=?", (installation_id,)).fetchone()
            if row is None:
                return
            revoked = Installation.model_validate_json(row["installation_json"]).model_copy(
                update={"status": InstallationStatus.revoked, "updated_at": now})
            conn.execute("UPDATE installations SET installation_json=?, env_keys_json=?, welcome_sent_at=NULL WHERE id=?",
                         (revoked.model_dump_json(), json.dumps([]), installation_id))

    def claim_welcome(self, installation_id: str) -> bool:
        with self._write() as conn:
            return conn.execute("UPDATE installations SET welcome_sent_at=? WHERE id=? AND welcome_sent_at IS NULL",
                                (self._clock(), installation_id)).rowcount == 1

    def release_welcome(self, installation_id: str) -> None:
        with self._write() as conn:
            conn.execute("UPDATE installations SET welcome_sent_at=NULL WHERE id=?", (installation_id,))

    def _append_current(self, conn: sqlite3.Connection, installation_id: str) -> None:
        row = conn.execute("SELECT state_json FROM setup_states WHERE installation_id=?", (installation_id,)).fetchone()
        if row is not None:
            self._append(conn, SetupState.model_validate_json(row["state_json"]))

    def set_binding(self, installation_id: str, space_id: str, bot: str, live: bool, hello_requested: bool) -> None:
        with self._write() as conn:
            before = conn.execute("SELECT live, hello_requested FROM bindings WHERE installation_id=? AND space_id=?",
                                  (installation_id, space_id)).fetchone()
            conn.execute(
                "INSERT INTO bindings (installation_id, space_id, bot, live, hello_requested) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(installation_id, space_id) DO UPDATE SET live=excluded.live, "
                "hello_requested=MAX(bindings.hello_requested, excluded.hello_requested)",
                (installation_id, space_id, bot, int(live), int(hello_requested)))
            if before is None or bool(before["live"]) != live:
                self._append_current(conn, installation_id)

    def set_live(self, installation_id: str, space_id: str, live: bool) -> bool:
        with self._write() as conn:
            changed = conn.execute("UPDATE bindings SET live=? WHERE installation_id=? AND space_id=? AND live != ?",
                                   (int(live), installation_id, space_id, int(live))).rowcount == 1
            if changed:
                self._append_current(conn, installation_id)
        return changed

    def binding(self, installation_id: str, space_id: str) -> BindingRow | None:
        with self._read() as conn:
            row = conn.execute("SELECT * FROM bindings WHERE installation_id=? AND space_id=?",
                               (installation_id, space_id)).fetchone()
        return _binding(row) if row else None

    def bindings(self, bot: str) -> list[BindingRow]:
        with self._read() as conn:
            rows = conn.execute("SELECT * FROM bindings WHERE bot=? ORDER BY installation_id, space_id", (bot,)).fetchall()
        return [_binding(row) for row in rows]

    def delete_bindings(self, installation_id: str) -> None:
        with self._write() as conn:
            conn.execute("DELETE FROM bindings WHERE installation_id=?", (installation_id,))

    def claim_hello(self, installation_id: str, space_id: str) -> bool:
        with self._write() as conn:
            return conn.execute(
                "UPDATE bindings SET hello_sent_at=? WHERE installation_id=? AND space_id=? "
                "AND hello_requested=1 AND hello_sent_at IS NULL", (self._clock(), installation_id, space_id)).rowcount == 1

    def release_hello(self, installation_id: str, space_id: str) -> None:
        with self._write() as conn:
            conn.execute("UPDATE bindings SET hello_sent_at=NULL WHERE installation_id=? AND space_id=?",
                         (installation_id, space_id))


def _binding(row: sqlite3.Row) -> BindingRow:
    return BindingRow(row["installation_id"], row["space_id"], row["bot"], bool(row["live"]),
                      bool(row["hello_requested"]), row["hello_sent_at"])
