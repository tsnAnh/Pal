"""Session-backed MCP OAuth flows for gateway RPC and connection-card callback relays.

The worker and callback receiver selection live in ``tools/connectors/mcp_oauth.py``. This module
owns flow registration, profile checks, polling, cancellation, and relayed callback delivery.
"""

from __future__ import annotations

import hmac
import secrets
import threading
import time
from contextlib import suppress
from typing import Any, Dict, Optional
from urllib.parse import parse_qs, urlparse

from tools.connectors.mcp_oauth import (
    _pinned_loopback,
    _validate_client_redirect_uri,
    choose_callback_receiver,
    run_worker,
    validate_loopback_redirect_uri,
)
from tools.connectors.mcp_oauth_redirect import (
    ADMIN_APPROVAL_MESSAGE,
    APP_REDIRECT_URI,
    KIND_APP,
    KIND_GATEWAY,
    KIND_LOOPBACK,
    is_app_redirect,
    is_registration_refusal,
)
from tui_gateway import mcp_oauth_redirects


class AdminApprovalPending(RuntimeError):
    """The vendor says an admin of the owner's organisation must approve Pal; carries no vendor text."""


# session_id -> record wrapping the shared DashboardOAuthFlow bridge plus bookkeeping.
_sessions: dict[str, dict[str, Any]] = {}
_sessions_lock = threading.Lock()

_SESSION_TTL_SECONDS = 900  # completed/abandoned session lingers this long before GC
_MAX_PENDING = 12  # cap in-flight flows so a runaway client can't exhaust ports/threads


def _shutdown_listener(rec: dict[str, Any]) -> None:
    server = rec.get("httpd")
    if server is None:
        return
    for stop in (server.shutdown, server.server_close):
        with suppress(Exception):
            stop()
    rec["httpd"] = None


def register_flow(flow, *, httpd=None) -> dict[str, Any]:
    """Register a callback-relay flow so both RPC and card starts share ownership checks."""
    rec = {
        "session_id": flow.flow_id,
        "server_name": flow.server_name,
        "hermes_home": flow.hermes_home,
        "flow": flow,
        "httpd": httpd,
        "created_at": time.time(),
    }
    with _sessions_lock:
        _sessions[flow.flow_id] = rec
    return rec


def finish_flow(session_id: str) -> None:
    """Release a finished flow's backend listener without removing relay-visible outcome state."""
    with _sessions_lock:
        rec = _sessions.get(session_id)
    if rec is not None:
        _shutdown_listener(rec)


def _gc_and_check_capacity(server_name: str, hermes_home: str) -> None:
    cutoff = time.time() - _SESSION_TTL_SECONDS  # opportunistic GC of expired sessions
    with _sessions_lock:
        for sid in [sid for sid, rec in _sessions.items() if rec["created_at"] < cutoff]:
            _shutdown_listener(_sessions.pop(sid))
    with _sessions_lock:
        active = [r for r in _sessions.values() if not r["flow"].worker_done]
        if len(active) >= _MAX_PENDING:
            raise RuntimeError("Too many MCP OAuth flows are already in progress")
        if any(r["server_name"] == server_name and r["hermes_home"] == hermes_home for r in active):
            raise RuntimeError(f"MCP OAuth for '{server_name}' is already in progress")


def _remember_approval(rec: dict[str, Any]) -> None:
    if rec["flow"].snapshot().get("status") != "approved":
        return
    with suppress(Exception):
        mcp_oauth_redirects.save_pref(rec["hermes_home"], rec["server_name"], kind=rec["redirect"])


def _launch(
    hermes_home: str, server_name: str, cfg: dict, reconnect_live: bool, kind: str,
    redirect_uri: Optional[str]) -> dict[str, Any]:
    """Start one fresh flow on one redirect. ``redirect_uri`` None means the gateway-hosted loopback receiver."""
    from tools.mcp_dashboard_oauth import DashboardOAuthFlow
    session_id = secrets.token_urlsafe(24)
    flow = DashboardOAuthFlow(
        flow_id=session_id, server_name=server_name, hermes_home=hermes_home,
        redirect_uri=redirect_uri if kind == KIND_GATEWAY else "", reconnect_live=reconnect_live)
    httpd = None if kind == KIND_GATEWAY else choose_callback_receiver(flow, cfg, redirect_uri)
    rec = register_flow(flow, httpd=httpd)
    rec["redirect"] = kind
    threading.Thread(
        target=run_worker, args=(hermes_home, server_name, dict(cfg), reconnect_live),
        kwargs={"flow": flow, "on_done": lambda: (_remember_approval(rec), _shutdown_listener(rec))},
        daemon=True, name=f"mcp-oauth-{server_name}").start()
    return rec


def _publish(rec: dict[str, Any], url_timeout: float) -> dict[str, Any]:
    """Wait for the flow's authorization URL; a failure marks the flow errored and releases its listener."""
    flow = rec["flow"]
    try:
        auth_url = None
        deadline = time.time() + url_timeout
        while time.time() < deadline:
            snap = flow.snapshot()
            if auth_url := snap.get("authorization_url"):
                break
            if snap.get("status") == "error":
                raise RuntimeError(
                    snap.get("error") or "MCP OAuth flow failed before authorization")
            time.sleep(0.1)
        if not auth_url:
            raise TimeoutError("Timed out waiting for MCP authorization URL")
    except Exception as exc:
        from tools.mcp_dashboard_oauth import exception_message
        flow.mark_error(exception_message(exc))  # no-op when the worker already recorded the cause
        _shutdown_listener(rec)
        if flow.reason:
            raise AdminApprovalPending(ADMIN_APPROVAL_MESSAGE) from None
        raise
    if rec["redirect"] == KIND_GATEWAY:
        rec["gateway_state"] = parse_qs(urlparse(auth_url).query).get("state", [None])[0]
    return {"session_id": flow.flow_id, "auth_url": auth_url, "flow": "pkce", "redirect": rec["redirect"],
            "redirect_uri": flow.redirect_uri}


def _retire(rec: dict[str, Any]) -> None:
    """Drop a refused attempt once its worker has rolled back, so the next one owns the token files."""
    flow = rec["flow"]
    flow.mark_error("OAuth cancelled by user", cancelled=True)
    _shutdown_listener(rec)
    if not flow.wait_worker_done(10):
        raise RuntimeError(f"MCP OAuth for '{rec['server_name']}' could not be restarted; try again shortly")
    with _sessions_lock:
        _sessions.pop(flow.flow_id, None)


def _supersede_active(server_name: str, hermes_home: str) -> None:
    """An abandoned attempt (closed browser, killed app) holds the slot until its callback wait times out."""
    with _sessions_lock:
        stale = [r for r in _sessions.values()
                 if r["server_name"] == server_name and r["hermes_home"] == hermes_home and not r["flow"].worker_done]
    for rec in stale:
        _retire(rec)


def _run_chain(
    hermes_home: str, server_name: str, cfg: dict, reconnect_live: bool, url_timeout: float,
    fallback: Optional[str]) -> dict[str, Any]:
    pref = mcp_oauth_redirects.load_pref(hermes_home, server_name)
    gateway = mcp_oauth_redirects.gateway_redirect_uri(hermes_home)
    uris = {KIND_APP: APP_REDIRECT_URI, KIND_GATEWAY: gateway, KIND_LOOPBACK: fallback}
    notice = None
    for kind in mcp_oauth_redirects.steps_from(pref.get("kind")):
        if kind == KIND_GATEWAY and gateway is None:
            notice = mcp_oauth_redirects.NOTICE
            continue
        rec = _launch(hermes_home, server_name, cfg, reconnect_live, kind, uris[kind])
        try:
            result = _publish(rec, url_timeout)
        except Exception as exc:
            if kind == KIND_LOOPBACK or not is_registration_refusal(str(exc)):
                raise
            _retire(rec)
            continue
        if notice and not pref.get("notice_shown"):
            result["notice"] = notice
            mcp_oauth_redirects.save_pref(hermes_home, server_name, notice_shown=True)
        return result
    raise RuntimeError("MCP OAuth could not start on any redirect")


def start_flow(
    hermes_home: str, server_name: str, cfg: dict, *, reconnect_live: bool = False,
    url_timeout: float = 30.0, client_redirect_uri: Optional[str] = None,
    fallback_redirect_uri: Optional[str] = None) -> dict[str, Any]:
    """Begin an MCP OAuth flow and return ``{session_id, auth_url, flow, redirect, redirect_uri}`` (plus a
    ``notice`` when the gateway has no https address); blocks up to ``url_timeout`` for the authorization
    URL. With a loopback ``client_redirect_uri`` (invalid values raise ``ValueError``) no gateway-side
    listener is bound. With the Pal app's redirect the chain app, gateway https, loopback runs, moving on
    only when the server refuses the registered redirect; ``fallback_redirect_uri`` is the client-hosted
    loopback for the last step."""
    from tools.mcp_oauth import signs_in_on_owner_app
    if signs_in_on_owner_app(cfg):
        raise RuntimeError(f"'{server_name}' signs in on your own computer, not on this host. Sign in from the Pal app on your phone, tablet or Mac.")
    if client_redirect_uri is not None:
        client_redirect_uri = _validate_client_redirect_uri(client_redirect_uri)
    if fallback_redirect_uri is not None:
        fallback_redirect_uri = validate_loopback_redirect_uri(fallback_redirect_uri)
    _supersede_active(server_name, hermes_home)
    _gc_and_check_capacity(server_name, hermes_home)
    if client_redirect_uri is not None and is_app_redirect(client_redirect_uri) and not _pinned_loopback(cfg):
        return _run_chain(hermes_home, server_name, cfg, reconnect_live, url_timeout, fallback_redirect_uri)
    rec = _launch(hermes_home, server_name, cfg, reconnect_live, KIND_LOOPBACK, client_redirect_uri)
    return _publish(rec, url_timeout)


def start_gateway_flow(hermes_home: str, server_name: str, cfg: dict, redirect_uri: str) -> dict[str, Any]:
    """Begin a flow whose vendor-registered redirect is the gateway's https callback (a preregistered client
    cannot be retried on another redirect); the session returns through ``deliver_gateway_callback``."""
    _gc_and_check_capacity(server_name, hermes_home)
    rec = _launch(hermes_home, server_name, cfg, False, KIND_GATEWAY, redirect_uri)
    return _publish(rec, 30.0)


def deliver_gateway_callback(
    state: str, *, code: Optional[str], error: Optional[str] = None, iss: Optional[str] = None,
    error_description: Optional[str] = None) -> bool:
    """Hand the https callback route's redirect to the flow that minted ``state``. A state works once and
    only while its session lives; True when delivered."""
    cutoff = time.time() - _SESSION_TTL_SECONDS
    match = None
    with _sessions_lock:
        for rec in _sessions.values():
            expected = rec.get("gateway_state")
            if expected and hmac.compare_digest(expected.encode(), state.encode()) and rec["created_at"] >= cutoff:
                match, rec["gateway_state"] = rec, None
    if match is None:
        return False
    try:
        match["flow"].deliver_callback(
            code=code, state=state, error=error, iss=iss, error_description=error_description)
    except ValueError:
        return False
    return True


def _lookup(
    session_id: str, server_name: str, hermes_home: Optional[str] = None,
) -> tuple[dict[str, Any] | None, str | None]:
    """Find a session belonging to the caller's resolved profile."""
    from hermes_constants import hermes_home_key
    with _sessions_lock:
        rec = _sessions.get(session_id)
    if rec is None:
        return None, "OAuth session not found or expired"
    if rec["server_name"] != server_name:
        return None, "server name mismatch for session"
    if hermes_home_key(rec["hermes_home"]) != hermes_home_key(hermes_home):
        return None, "profile mismatch for session"
    return rec, None


def poll_flow(session_id: str, server_name: str) -> dict[str, Any]:
    """Poll a session → ``{status, error_message?, reason?, auth_url?, tools?}``; ``status`` is
    ``pending`` | ``approved`` | ``error`` (the bridge's ``authorization_required`` maps to
    ``pending``). ``reason`` is ``ADMIN_APPROVAL_PENDING`` with a fixed ``error_message`` when an admin
    must approve; the vendor's own text never leaves the gateway then."""
    rec, err = _lookup(session_id, server_name)
    if rec is None:
        return {"status": "error", "error_message": err}
    flow = rec["flow"]
    snap = flow.snapshot()
    raw = snap.get("status")
    status = raw if raw in ("approved", "error") else "pending"
    out: dict[str, Any] = {
        "session_id": session_id, "status": status, "error_message": snap.get("error"),
        "auth_url": snap.get("authorization_url"), "redirect": rec.get("redirect", KIND_LOOPBACK)}
    if status == "error" and flow.reason:
        out.update(reason=flow.reason, error_message=ADMIN_APPROVAL_MESSAGE)
    if status == "approved":
        out["tools"] = list(getattr(flow, "tools", []) or [])
    return out


def cancel_flow(session_id: str, server_name: str, hermes_home: str) -> dict[str, Any]:
    """Cancel only the owning profile's flow and release its callback waiter."""
    rec, err = _lookup(session_id, server_name, hermes_home)
    if rec is None:
        return {"ok": False, "error_message": err}
    flow = rec["flow"]
    flow.mark_error("OAuth cancelled by user", cancelled=True)
    _shutdown_listener(rec)
    return {"ok": True, "status": flow.snapshot()["status"]}


def deliver_callback_flow(
    session_id: str, server_name: str, *, code: Optional[str], state: Optional[str],
    error: Optional[str] = None, iss: Optional[str] = None,
    error_description: Optional[str] = None) -> dict[str, Any]:
    """Relay a client-captured OAuth redirect into a session's flow (remote-backend companion
    to ``start_flow(client_redirect_uri=...)``); ``deliver_callback`` still verifies ``state``
    and rejects replays. Returns ``{ok: true}`` or ``{ok: false, error_message}``."""
    rec, err = _lookup(session_id, server_name)
    if rec is None:
        return {"ok": False, "error_message": err}
    try:
        rec["flow"].deliver_callback(
            code=code, state=state, error=error, iss=iss, error_description=error_description)
    except ValueError as exc:
        return {"ok": False, "error_message": str(exc)}
    return {"ok": True, "session_id": session_id}


def pending_callback(session_id: str, server_name: str, hermes_home: str) -> tuple[str, str] | None:
    """The registered redirect and the state a pasted address must carry, for the owning profile only."""
    rec, _ = _lookup(session_id, server_name, hermes_home)
    if rec is None:
        return None
    flow = rec["flow"]
    state = flow.expected_state
    return (flow.redirect_uri, state) if state and flow.redirect_uri else None
