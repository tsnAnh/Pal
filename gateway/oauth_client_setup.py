from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import ipaddress
import logging
import os
import secrets
import sqlite3
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from enum import Enum
from pathlib import Path
from urllib.parse import urlencode, urlsplit

from gateway.device_registry import install_root

logger = logging.getLogger(__name__)

DB_NAME = "oauth_clients.db"
NONCE_TTL_SECONDS = 600.0
HTTP_TIMEOUT_SECONDS = 15.0
GOOGLE_REDIRECT_PATH = "/webapp/google-install/callback"
GOOGLE_PROVIDER = "google-workspace"
MCP_OAUTH_REDIRECT_PATH = "/webapp/mcp-oauth/callback"
MCP_REDIRECT_PORT = 27890
MCP_REDIRECT_URL = f"http://localhost:{MCP_REDIRECT_PORT}/callback"
GOOGLE_TOKEN_FILE = "google_token.json"
GOOGLE_IDENTITY_SCOPES = ("openid", "email")

CONSOLE_URLS = {
    GOOGLE_PROVIDER: "https://console.cloud.google.com/apis/credentials",
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS clients (
    provider_id TEXT PRIMARY KEY,
    vault_home TEXT NOT NULL,
    client_id_item TEXT NOT NULL,
    client_secret_item TEXT NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS connections (
    provider_id TEXT NOT NULL,
    profile_home TEXT NOT NULL,
    token_item TEXT,
    status TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (provider_id, profile_home)
);
CREATE TABLE IF NOT EXISTS nonces (
    digest TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    profile_home TEXT NOT NULL,
    verifier TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    expires_at REAL NOT NULL
);
"""


class ConnectionStatus(Enum):
    connected = "connected"
    needs_reconnect = "needs_reconnect"


class RedirectOutcome(Enum):
    completed = "completed"
    denied = "denied"
    rejected = "rejected"


class SetupError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class ClientRecord:
    provider_id: str
    vault_home: str
    client_id_item: str
    client_secret_item: str


@dataclass(frozen=True)
class PendingSignIn:
    provider_id: str
    profile_home: str
    verifier: str
    redirect_uri: str


def _digest(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def profile_key(home) -> str:
    return str(Path(home).expanduser().resolve(strict=False))


def vault_for(home):
    from agent.vault_store import VaultStore
    return VaultStore(base_dir=Path(home) / "vault")


class OAuthClientStore:
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

    @contextlib.contextmanager
    def _read(self) -> Iterator[sqlite3.Connection]:
        conn = self._open()
        try:
            yield conn
        finally:
            conn.close()

    def client(self, provider_id: str) -> ClientRecord | None:
        with self._read() as conn:
            row = conn.execute("SELECT * FROM clients WHERE provider_id=?", (provider_id,)).fetchone()
        if row is None:
            return None
        return ClientRecord(row["provider_id"], row["vault_home"], row["client_id_item"], row["client_secret_item"])

    def save_client(self, record: ClientRecord) -> ClientRecord | None:
        with self._write() as conn:
            row = conn.execute("SELECT * FROM clients WHERE provider_id=?", (record.provider_id,)).fetchone()
            conn.execute(
                "INSERT OR REPLACE INTO clients (provider_id, vault_home, client_id_item, client_secret_item, updated_at)"
                " VALUES (?, ?, ?, ?, ?)",
                (record.provider_id, record.vault_home, record.client_id_item, record.client_secret_item, self._clock()))
        if row is None:
            return None
        return ClientRecord(row["provider_id"], row["vault_home"], row["client_id_item"], row["client_secret_item"])

    def delete_client(self, provider_id: str) -> ClientRecord | None:
        with self._write() as conn:
            row = conn.execute("SELECT * FROM clients WHERE provider_id=?", (provider_id,)).fetchone()
            conn.execute("DELETE FROM clients WHERE provider_id=?", (provider_id,))
        if row is None:
            return None
        return ClientRecord(row["provider_id"], row["vault_home"], row["client_id_item"], row["client_secret_item"])

    def connection(self, provider_id: str, profile_home: str) -> tuple[ConnectionStatus, str | None] | None:
        with self._read() as conn:
            row = conn.execute("SELECT status, token_item FROM connections WHERE provider_id=? AND profile_home=?",
                               (provider_id, profile_home)).fetchone()
        return None if row is None else (ConnectionStatus(row["status"]), row["token_item"])

    def set_connection(self, provider_id: str, profile_home: str, status: ConnectionStatus,
                       token_item: str | None) -> None:
        with self._write() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO connections (provider_id, profile_home, token_item, status, updated_at)"
                " VALUES (?, ?, ?, ?, ?)", (provider_id, profile_home, token_item, status.value, self._clock()))

    def delete_connection(self, provider_id: str, profile_home: str) -> str | None:
        with self._write() as conn:
            row = conn.execute("SELECT token_item FROM connections WHERE provider_id=? AND profile_home=?",
                               (provider_id, profile_home)).fetchone()
            conn.execute("DELETE FROM connections WHERE provider_id=? AND profile_home=?", (provider_id, profile_home))
            conn.execute("DELETE FROM nonces WHERE provider_id=? AND profile_home=?", (provider_id, profile_home))
        return row["token_item"] if row else None

    def issue_nonce(self, pending: PendingSignIn, ttl: float = NONCE_TTL_SECONDS) -> str:
        raw = secrets.token_urlsafe(32)
        with self._write() as conn:
            conn.execute("DELETE FROM nonces WHERE provider_id=? AND profile_home=?",
                         (pending.provider_id, pending.profile_home))
            conn.execute("DELETE FROM nonces WHERE expires_at <= ?", (self._clock(),))
            conn.execute(
                "INSERT INTO nonces (digest, provider_id, profile_home, verifier, redirect_uri, expires_at)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (_digest(raw), pending.provider_id, pending.profile_home, pending.verifier, pending.redirect_uri,
                 self._clock() + ttl))
        return raw

    def consume_nonce(self, raw: str) -> PendingSignIn | None:
        wanted = _digest(raw)
        with self._write() as conn:
            row = conn.execute("SELECT * FROM nonces WHERE digest=?", (wanted,)).fetchone()
            if row is None or not hmac.compare_digest(row["digest"], wanted):
                return None
            conn.execute("DELETE FROM nonces WHERE digest=?", (wanted,))
        if row["expires_at"] <= self._clock():
            return None
        return PendingSignIn(row["provider_id"], row["profile_home"], row["verifier"], row["redirect_uri"])


def resolve_client(record: ClientRecord) -> tuple[str, str]:
    from agent.vault_store import VaultError
    vault = vault_for(record.vault_home)
    try:
        client_id = str(vault.resolve_secret(record.client_id_item).get("api_key") or "").strip()
        client_secret = str(vault.resolve_secret(record.client_secret_item).get("api_key") or "").strip()
    except VaultError:
        raise SetupError("client_unreadable") from None
    if not client_id or not client_secret:
        raise SetupError("client_unreadable")
    return client_id, client_secret


def save_client(store: OAuthClientStore, provider_id: str, vault_home, client_id_item: str,
                client_secret_item: str) -> None:
    record = ClientRecord(provider_id, profile_key(vault_home), client_id_item, client_secret_item)
    client_id, _ = resolve_client(record)
    if provider_id == GOOGLE_PROVIDER and not client_id.endswith(".apps.googleusercontent.com"):
        raise SetupError("invalid_client")
    previous = store.save_client(record)
    if previous is not None and previous != record:
        vault = vault_for(previous.vault_home)
        for item in {previous.client_id_item, previous.client_secret_item} - {client_id_item, client_secret_item}:
            with contextlib.suppress(Exception):
                vault.remove_item(item)


def remove_client(store: OAuthClientStore, provider_id: str) -> bool:
    record = store.delete_client(provider_id)
    if record is None:
        return False
    vault = vault_for(record.vault_home)
    for item in {record.client_id_item, record.client_secret_item}:
        with contextlib.suppress(Exception):
            vault.remove_item(item)
    return True


def _https_redirect(public_url: str | None, path: str) -> str | None:
    if not (public_url or "").startswith("https://"):
        return None
    return public_url.rstrip("/") + path


def google_redirect_url(public_url: str | None) -> str | None:
    return _https_redirect(public_url, GOOGLE_REDIRECT_PATH)


def mcp_redirect_url(public_url: str | None) -> str | None:
    return _https_redirect(public_url, MCP_OAUTH_REDIRECT_PATH)


def address_problem(public_url: str | None) -> tuple[str, str] | None:
    raw = (public_url or "").strip()
    if not raw:
        return None
    parts = urlsplit(raw)
    host = parts.hostname or ""
    if parts.scheme != "https":
        return "not_https", host
    with contextlib.suppress(ValueError):
        ipaddress.ip_address(host)
        return "ip_host", host
    return None


def _challenge(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


def google_begin(store: OAuthClientStore, profile_home, public_url: str | None) -> str:
    from hermes_cli.pal_connectors import load_pal_connectors
    redirect_uri = google_redirect_url(public_url)
    if redirect_uri is None:
        raise SetupError("needs_public_url")
    record = store.client(GOOGLE_PROVIDER)
    if record is None:
        raise SetupError("needs_setup")
    client_id, _ = resolve_client(record)
    entry = next(e for e in load_pal_connectors() if e.id == GOOGLE_PROVIDER)
    verifier = secrets.token_urlsafe(64)
    state = store.issue_nonce(PendingSignIn(GOOGLE_PROVIDER, profile_key(profile_home), verifier, redirect_uri))
    query = urlencode({
        "client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code",
        "scope": " ".join(dict.fromkeys([*GOOGLE_IDENTITY_SCOPES, *entry.scopes])), "state": state,
        "code_challenge": _challenge(verifier), "code_challenge_method": "S256", "access_type": "offline",
        "include_granted_scopes": "true", "prompt": "consent",
    })
    return f"{entry.oauth.authorization_url}?{query}"


def exchange_code(token_url: str, data: dict[str, str]) -> dict:
    import httpx
    response = httpx.post(token_url, data=data, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False)
    reply = response.json()
    if response.status_code != 200 or not isinstance(reply, dict) or not reply.get("access_token"):
        raise SetupError("rejected")
    return reply


def _store_google_token(pending: PendingSignIn, client_id: str, client_secret: str, reply: dict,
                        previous_item: str | None) -> str:
    from tui_gateway.google_workspace import EXPIRY_FORMAT, TOKEN_URI
    from utils import atomic_json_write
    vault = vault_for(pending.profile_home)
    refresh = reply.get("refresh_token")
    if not refresh and previous_item:
        refresh = str(vault.resolve_secret(previous_item).get("api_key") or "")
    if not refresh:
        raise SetupError("no_refresh_token")
    if previous_item:
        vault.update_item(previous_item, secret={"api_key": refresh})
        item_id = previous_item
    else:
        item_id = vault.add_item("api_key", "Google Workspace sign-in", {"api_key": refresh}).id
    expiry = datetime.now(UTC) + timedelta(seconds=int(reply.get("expires_in") or 3600))
    atomic_json_write(Path(pending.profile_home) / GOOGLE_TOKEN_FILE, {
        "token": reply["access_token"], "refresh_token": refresh, "token_uri": TOKEN_URI,
        "client_id": client_id, "client_secret": client_secret,
        "scopes": str(reply.get("scope") or "").split(), "universe_domain": "googleapis.com",
        "account": "", "expiry": expiry.strftime(EXPIRY_FORMAT), "type": "authorized_user"}, mode=0o600)
    return item_id


def google_complete(store: OAuthClientStore, raw_state: str, code: str | None, error: str | None,
                    exchange: Callable[[str, dict[str, str]], dict] | None = None) -> RedirectOutcome:
    pending = store.consume_nonce(raw_state) if raw_state else None
    if pending is None or pending.provider_id != GOOGLE_PROVIDER:
        return RedirectOutcome.rejected
    if error:
        return RedirectOutcome.denied
    if not code:
        return RedirectOutcome.rejected
    from hermes_cli.pal_connectors import load_pal_connectors
    record = store.client(GOOGLE_PROVIDER)
    previous = store.connection(GOOGLE_PROVIDER, pending.profile_home)
    try:
        if record is None:
            raise SetupError("needs_setup")
        client_id, client_secret = resolve_client(record)
        entry = next(e for e in load_pal_connectors() if e.id == GOOGLE_PROVIDER)
        reply = (exchange or exchange_code)(entry.oauth.token_url, {
            "client_id": client_id, "client_secret": client_secret, "code": code, "code_verifier": pending.verifier,
            "grant_type": "authorization_code", "redirect_uri": pending.redirect_uri})
        item = _store_google_token(pending, client_id, client_secret, reply, previous[1] if previous else None)
    except Exception as exc:  # health: allow BLE001 -- provider and vault errors may carry the code, so only the type is logged
        logger.warning("google install exchange failed error=%s", type(exc).__name__)
        store.set_connection(GOOGLE_PROVIDER, pending.profile_home, ConnectionStatus.needs_reconnect,
                             previous[1] if previous else None)
        return RedirectOutcome.denied
    store.set_connection(GOOGLE_PROVIDER, pending.profile_home, ConnectionStatus.connected, item)
    return RedirectOutcome.completed


def google_remove(store: OAuthClientStore, profile_home) -> None:
    key = profile_key(profile_home)
    item = store.delete_connection(GOOGLE_PROVIDER, key)
    if item:
        with contextlib.suppress(Exception):
            vault_for(key).remove_item(item)
    (Path(key) / GOOGLE_TOKEN_FILE).unlink(missing_ok=True)


def google_status(store: OAuthClientStore, profile_home) -> ConnectionStatus | None:
    row = store.connection(GOOGLE_PROVIDER, profile_key(profile_home))
    return row[0] if row else None


def preregistered_mcp_entries() -> dict:
    from hermes_cli.pal_connectors import ConnectionMethod, load_pal_connectors
    return {e.id: e for e in load_pal_connectors() if e.method is ConnectionMethod.OAUTH_CLIENT and e.mcp_url}


def mcp_secret_env(provider_id: str) -> str:
    return provider_id.upper().replace("-", "_") + "_CLIENT_SECRET"


def mcp_server_config(provider_id: str, client_id: str) -> dict:
    entry = preregistered_mcp_entries()[provider_id]
    return {"url": entry.mcp_url, "transport": "http", "auth": "oauth",
            "oauth": {"client_id": client_id, "client_secret": f"${{{mcp_secret_env(provider_id)}}}",
                      "redirect_host": "localhost", "redirect_port": MCP_REDIRECT_PORT}}


def console_url(provider_id: str) -> str:
    from hermes_cli.pal_connectors import load_pal_connectors
    return CONSOLE_URLS.get(provider_id) or next(e.source for e in load_pal_connectors() if e.id == provider_id)


def build_store(home=None) -> OAuthClientStore:
    from hermes_constants import get_hermes_home
    return OAuthClientStore(home or get_hermes_home())
