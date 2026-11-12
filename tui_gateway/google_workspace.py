"""Writes the two files the google-workspace skill reads (google_client_secret.json, google_token.json, google-auth
authorized_user shape) so the skill works unmodified. The Desktop client's loopback redirect cannot be served here, so
sign-in is code + PKCE with the verifier held under a flow id and the owner pasting the address the browser ended on."""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import secrets
import threading
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode

import httpx

from gateway.auth_flows import PASTE_MAX_RETRIES, PASTE_TTL_SECONDS
from hermes_cli.oauth_paste import CallbackError, parse_callback
from hermes_constants import get_hermes_home
from utils import atomic_json_write

logger = logging.getLogger(__name__)

AUTH_URI = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URI = "https://oauth2.googleapis.com/token"
REVOKE_URI = "https://oauth2.googleapis.com/revoke"
USERINFO_URI = "https://openid.googleapis.com/v1/userinfo"
HTTP_TIMEOUT_SECONDS = 15.0
EXPIRY_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
EXPIRY_SKEW = timedelta(seconds=60)
MAX_PENDING_FLOWS = 4
MAX_CLIENT_JSON_CHARS = 16384

TOKEN_FILE = "google_token.json"
CLIENT_FILE = "google_client_secret.json"
MARKER_FILE = "google_pal_status.json"

_API = "https://www.googleapis.com/auth/"
IDENTITY_SCOPES = ("openid", "email")
SERVICES: dict[str, dict[str, tuple[str, ...]]] = {
    "gmail": {"read": (_API + "gmail.readonly",), "write": (_API + "gmail.send", _API + "gmail.modify")},
    "calendar": {"read": (_API + "calendar.readonly",), "write": (_API + "calendar",)},
    "drive": {"read": (_API + "drive.readonly",), "write": (_API + "drive",)},
    "contacts": {"read": (_API + "contacts.readonly",), "write": ()},
    "sheets": {"read": (_API + "spreadsheets.readonly",), "write": (_API + "spreadsheets",)},
    "docs": {"read": (_API + "documents.readonly",), "write": (_API + "documents",)},
}
_FULL_ACCESS = {"calendar", "drive", "sheets", "docs"}


class WorkspaceError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _home():
    return get_hermes_home()


def _read_json(name: str) -> dict | None:
    try:
        data = json.loads((_home() / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_private(name: str, data: dict) -> None:
    atomic_json_write(_home() / name, data, mode=0o600)


def _remove(name: str) -> None:
    (_home() / name).unlink(missing_ok=True)


def _client() -> dict | None:
    installed = (_read_json(CLIENT_FILE) or {}).get("installed")
    if isinstance(installed, dict) and installed.get("client_id") and installed.get("client_secret"):
        return installed
    return None


def _marker() -> dict:
    return _read_json(MARKER_FILE) or {}


def _set_marker(**fields) -> None:
    _write_private(MARKER_FILE, {**_marker(), **fields})


def scopes_for(services: list[str], write: list[str]) -> list[str]:
    unknown = [s for s in (*services, *write) if s not in SERVICES]
    if unknown or not services or set(write) - set(services):
        raise WorkspaceError("invalid_services", "Pick at least one service, and only turn on write access for services you picked.")
    if any(not SERVICES[s]["write"] for s in write):
        raise WorkspaceError("invalid_services", "That service is read-only.")
    scopes = list(IDENTITY_SCOPES)
    for name in services:
        scopes += SERVICES[name]["read"]
        if name in write:
            scopes += SERVICES[name]["write"]
    return list(dict.fromkeys(scopes))


def granted_services(scopes: list[str]) -> tuple[list[str], list[str]]:
    have = set(scopes)
    read, write = [], []
    for name, parts in SERVICES.items():
        can_write = any(s in have for s in parts["write"])
        if can_write:
            write.append(name)
        if can_write or any(s in have for s in parts["read"]):
            read.append(name)
    return read, write


def _token_scopes(token: dict) -> list[str]:
    raw = token.get("scopes") or token.get("scope") or []
    items = raw.split() if isinstance(raw, str) else raw
    return [s for s in items if isinstance(s, str)]


def _parse_expiry(raw) -> datetime | None:
    try:
        return datetime.strptime(str(raw).rstrip("Z").split(".")[0], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=UTC)
    except ValueError:
        return None


def status() -> dict:
    base = {"state": "not_configured", "email": None, "services": [], "write_services": [], "reauth_reason": None}
    if _client() is None:
        return base
    marker = _marker()
    token_path = _home() / TOKEN_FILE
    if not token_path.exists():
        if marker.get("signed_in"):
            return {**base, "state": "reauth_needed", "reauth_reason": "token_missing"}
        return {**base, "state": "needs_sign_in"}
    token = _read_json(TOKEN_FILE)
    if token is None or not token.get("refresh_token") or not token.get("client_id"):
        return {**base, "state": "reauth_needed", "reauth_reason": "token_unreadable"}
    services, write = granted_services(_token_scopes(token))
    email = token.get("account") if isinstance(token.get("account"), str) and token.get("account") else None
    state = "reauth_needed" if marker.get("reauth") else "signed_in"
    return {"state": state, "email": email, "services": services, "write_services": write,
            "reauth_reason": marker.get("reauth")}


def _client_from_text(client_json: str | None, client_id: str | None, client_secret: str | None) -> dict:
    if client_json and client_json.strip():
        if len(client_json) > MAX_CLIENT_JSON_CHARS:
            raise WorkspaceError("invalid_client", "That doesn't look like Google's client file.")
        try:
            data = json.loads(client_json)
        except ValueError:
            raise WorkspaceError("invalid_client", "That doesn't look like Google's client file.") from None
        if isinstance(data, dict) and "web" in data and "installed" not in data:
            raise WorkspaceError("not_desktop_client", "That is a web client. Create an OAuth client of type Desktop app instead.")
        section = data.get("installed") if isinstance(data, dict) else None
        if not isinstance(section, dict):
            raise WorkspaceError("invalid_client", "That doesn't look like Google's client file.")
        client_id, client_secret = section.get("client_id"), section.get("client_secret")
        project_id = section.get("project_id")
    else:
        project_id = None
    if not isinstance(client_id, str) or not isinstance(client_secret, str):
        raise WorkspaceError("invalid_client", "Enter the client ID and client secret, or paste Google's client file.")
    client_id, client_secret = client_id.strip(), client_secret.strip()
    if not client_id.endswith(".apps.googleusercontent.com") or not client_secret or len(client_id) > 256 or len(client_secret) > 256:
        raise WorkspaceError("invalid_client", "That doesn't look like a Google client ID and secret.")
    return {"client_id": client_id, "project_id": project_id if isinstance(project_id, str) else "",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth", "token_uri": TOKEN_URI,
            "client_secret": client_secret, "redirect_uris": ["http://localhost"]}


def set_client(client_json: str | None, client_id: str | None, client_secret: str | None) -> dict:
    installed = _client_from_text(client_json, client_id, client_secret)
    previous = (_client() or {}).get("client_id")
    _write_private(CLIENT_FILE, {"installed": installed})
    if previous != installed["client_id"]:
        _remove(TOKEN_FILE)
        _remove(MARKER_FILE)
        cancel_all()
    return status()


def _revoke(token: dict) -> None:
    for key in ("refresh_token", "token"):
        if token.get(key):
            try:
                httpx.post(REVOKE_URI, data={"token": token[key]}, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False)
            except httpx.HTTPError:
                logger.info("google revoke could not reach Google")
            return


def sign_out(remove_setup: bool = False) -> dict:
    token = _read_json(TOKEN_FILE)
    if token is not None:
        _revoke(token)
    _remove(TOKEN_FILE)
    _remove(MARKER_FILE)
    cancel_all()
    if remove_setup:
        _remove(CLIENT_FILE)
    return status()


@dataclass(eq=False)
class _Flow:
    flow_id: str
    verifier: str = field(repr=False)
    state: str = field(repr=False)
    redirect_uri: str
    client_id: str
    scopes: list[str]
    deadline: float
    attempts: int = 0
    consumed: bool = False


_lock = threading.RLock()
_flows: dict[str, _Flow] = {}
_clock = time.monotonic


def _challenge(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


def start_signin(services: list[str], write: list[str]) -> dict:
    client = _client()
    if client is None:
        raise WorkspaceError("not_configured", "Add your Google client first.")
    scopes = scopes_for(services, write)
    flow_id, verifier, state = secrets.token_urlsafe(24), secrets.token_urlsafe(64), secrets.token_urlsafe(32)
    port = 49152 + secrets.randbelow(16384)
    redirect_uri = f"http://127.0.0.1:{port}/"
    query = urlencode({
        "client_id": client["client_id"], "redirect_uri": redirect_uri, "response_type": "code",
        "scope": " ".join(scopes), "state": state, "code_challenge": _challenge(verifier),
        "code_challenge_method": "S256", "access_type": "offline", "include_granted_scopes": "true",
        "prompt": "consent",
    })
    now = _clock()
    with _lock:
        for fid in [fid for fid, f in _flows.items() if f.consumed or f.deadline <= now]:
            del _flows[fid]
        while len(_flows) >= MAX_PENDING_FLOWS:
            del _flows[next(iter(_flows))]
        _flows[flow_id] = _Flow(flow_id, verifier, state, redirect_uri, client["client_id"], scopes,
                                now + PASTE_TTL_SECONDS)
    return {"flow_id": flow_id, "auth_url": f"{AUTH_URI}?{query}", "expires_in": int(PASTE_TTL_SECONDS)}


def cancel(flow_id: str) -> None:
    with _lock:
        _flows.pop(flow_id, None)


def cancel_all() -> None:
    with _lock:
        _flows.clear()


def _failed(code: str, message: str) -> dict:
    return {"state": "failed", "code": code, "message": message, "status": None}


def finish_signin(flow_id: str, pasted: str) -> dict:
    with _lock:
        flow = _flows.get(flow_id)
        if flow is None or flow.consumed:
            return _failed("no_flow", "That sign-in is no longer open. Start again.")
        if _clock() >= flow.deadline:
            del _flows[flow_id]
            return _failed("expired", "The sign-in expired. Start again.")
        try:
            callback = parse_callback(pasted, redirect_uri=flow.redirect_uri, state=flow.state)
        except CallbackError as exc:
            flow.attempts += 1
            if exc.retry and flow.attempts < PASTE_MAX_RETRIES:
                return {"state": "retry", "code": exc.code, "message": exc.message, "status": None}
            del _flows[flow_id]
            return {"state": "denied" if exc.code == "denied" else "failed", "code": exc.code,
                    "message": exc.message, "status": None}
        flow.consumed = True
        del _flows[flow_id]
    return _complete(flow, callback.code)


def _complete(flow: _Flow, code: str) -> dict:
    client = _client()
    if client is None or client["client_id"] != flow.client_id:
        return _failed("client_changed", "The Google client changed during sign-in. Start again.")
    try:
        response = httpx.post(TOKEN_URI, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False, data={
            "client_id": client["client_id"], "client_secret": client["client_secret"], "code": code,
            "code_verifier": flow.verifier, "grant_type": "authorization_code", "redirect_uri": flow.redirect_uri})
        reply = response.json()
    except (httpx.HTTPError, ValueError):
        return _failed("unreachable", "Couldn't reach Google to finish signing in. Start again.")
    if response.status_code != 200 or not isinstance(reply, dict) or not reply.get("access_token"):
        logger.warning("google sign-in exchange refused (%s)", reply.get("error") if isinstance(reply, dict) else "unreadable")
        return _failed("rejected", "Google didn't accept the sign-in. Start again.")
    existing = _read_json(TOKEN_FILE) or {}
    refresh = reply.get("refresh_token") or existing.get("refresh_token")
    if not refresh:
        return _failed("no_refresh_token", "Google didn't allow ongoing access. Start again and approve every prompt.")
    granted = str(reply.get("scope") or "").split() or flow.scopes
    scopes = list(dict.fromkeys([*_token_scopes(existing), *granted]))
    email = _userinfo_email(reply["access_token"])
    expiry = datetime.now(UTC) + timedelta(seconds=int(reply.get("expires_in") or 3600))
    _write_private(TOKEN_FILE, {
        "token": reply["access_token"], "refresh_token": refresh, "token_uri": TOKEN_URI,
        "client_id": client["client_id"], "client_secret": client["client_secret"], "scopes": scopes,
        "universe_domain": "googleapis.com", "account": email or "", "expiry": expiry.strftime(EXPIRY_FORMAT),
        "type": "authorized_user"})
    _set_marker(signed_in=True, reauth=None)
    return {"state": "signed_in", "code": None, "message": None, "status": status()}


def _userinfo_email(access_token: str) -> str | None:
    try:
        response = httpx.get(USERINFO_URI, headers={"Authorization": f"Bearer {access_token}"},
                             timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False)
        email = response.json().get("email") if response.status_code == 200 else None
    except (httpx.HTTPError, ValueError, AttributeError):
        return None
    return email if isinstance(email, str) else None


def verify() -> dict:
    current = status()
    token = _read_json(TOKEN_FILE)
    if current["state"] not in ("signed_in", "reauth_needed") or token is None:
        return current
    expiry = _parse_expiry(token.get("expiry"))
    access = token.get("token")
    stale = not access or expiry is None or expiry - EXPIRY_SKEW <= datetime.now(UTC)
    if (stale or not _access_works(access)) and _refresh(token) is None:
        return status()
    _set_marker(signed_in=True, reauth=None)
    return status()


def _access_works(access: str) -> bool:
    try:
        return httpx.get(USERINFO_URI, headers={"Authorization": f"Bearer {access}"},
                         timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False).status_code != 401
    except httpx.HTTPError:
        raise WorkspaceError("unreachable", "Couldn't reach Google to check the sign-in.") from None


def _refresh(token: dict) -> str | None:
    try:
        response = httpx.post(TOKEN_URI, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False, data={
            "client_id": token.get("client_id"), "client_secret": token.get("client_secret"),
            "refresh_token": token.get("refresh_token"), "grant_type": "refresh_token"})
        reply = response.json()
    except httpx.HTTPError:
        raise WorkspaceError("unreachable", "Couldn't reach Google to check the sign-in.") from None
    except ValueError:
        reply = {}
    if response.status_code == 200 and isinstance(reply, dict) and reply.get("access_token"):
        expiry = datetime.now(UTC) + timedelta(seconds=int(reply.get("expires_in") or 3600))
        _write_private(TOKEN_FILE, {**token, "token": reply["access_token"], "expiry": expiry.strftime(EXPIRY_FORMAT)})
        return reply["access_token"]
    error = reply.get("error") if isinstance(reply, dict) else None
    if error in ("invalid_grant", "invalid_client", "unauthorized_client"):
        _set_marker(signed_in=True, reauth="revoked" if error == "invalid_grant" else "client_rejected")
        return None
    raise WorkspaceError("unreachable", "Google didn't answer as expected. Try again in a moment.")
