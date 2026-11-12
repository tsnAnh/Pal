"""GitHub OAuth device flow for ``github.oauth.*``: Pal's own OAuth App, client ID only, no secret.

GitHub is called directly over HTTPS (RFC 8628). The app polls this module, which asks GitHub at most once per
GitHub's interval, so no thread or process outlives a call and cancel, expiry and gateway stop only drop the
in-memory state. On success the token goes once to ``gh auth login --with-token`` on stdin and is never
returned, logged or read back.
"""

from __future__ import annotations

import atexit
import secrets
import threading
import time
from dataclasses import dataclass

import httpx

from tui_gateway import github_token
from tui_gateway.github_token import TokenError

DEVICE_CODE_URL = "https://github.com/login/device/code"
ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
SCOPES = " ".join(github_token.REQUIRED_SCOPES)
REQUEST_TIMEOUT_SECONDS = 15.0
SLOW_DOWN_SECONDS = 5
MAX_INTERVAL_SECONDS = 60
ORG_MARKERS = ("access restrictions", "access policy")

_REJECTED = {"incorrect_client_credentials", "device_flow_disabled", "unsupported_grant_type",
             "incorrect_device_code"}
_REJECTED_MESSAGE = "GitHub didn't accept Pal's app. Check the client ID and that Device Flow is on for the app."
_ORG_MESSAGE = "An organization restricts third-party apps. An organization owner must approve Pal."


@dataclass(eq=False)
class _Flow:
    session_id: str
    client_id: str
    device_code: str
    user_code: str
    verification_uri: str
    deadline: float
    interval: int
    next_poll: float
    result: dict | None = None


_lock = threading.RLock()
_current: _Flow | None = None
_clock = time.monotonic


def _post(url: str, form: dict) -> dict:
    try:
        response = httpx.post(url, data=form, headers={"Accept": "application/json"},
                              timeout=REQUEST_TIMEOUT_SECONDS, follow_redirects=False)
        body = response.json()
    except httpx.HTTPError:
        raise TokenError("unreachable", "Couldn't reach GitHub. Check the connection and try again.") from None
    except ValueError:
        raise TokenError("unreachable", "GitHub didn't answer as expected. Try again in a moment.") from None
    return body if isinstance(body, dict) else {}


def _start_data(flow: _Flow) -> dict:
    return {"session_id": flow.session_id, "user_code": flow.user_code,
            "verification_uri": flow.verification_uri, "expires_in": max(1, int(flow.deadline - _clock())),
            "interval": flow.interval}


def start() -> dict:
    """Begin a sign-in, or return the one still pending: only one flow runs per gateway."""
    global _current
    with _lock:
        if _current is not None and _current.result is None and _clock() < _current.deadline:
            return _start_data(_current)
        _current = None
        client_id = github_token.configured_client_id()
        if client_id is None:
            raise TokenError("oauth_app_not_configured", "Add Pal's GitHub app client ID in Settings first.")
        data = _post(DEVICE_CODE_URL, {"client_id": client_id, "scope": SCOPES})
        if data.get("error") in _REJECTED:
            raise TokenError("oauth_app_rejected", _REJECTED_MESSAGE)
        try:
            interval = max(1, int(data.get("interval", 5)))
            expires_in = int(data["expires_in"])
            flow = _Flow(secrets.token_urlsafe(12), client_id, str(data["device_code"]), str(data["user_code"]),
                         str(data["verification_uri"]), _clock() + expires_in, interval, _clock() + interval)
        except (KeyError, TypeError, ValueError):
            raise TokenError("unreachable", "GitHub didn't give a sign-in code. Try again.") from None
        _current = flow
        return _start_data(flow)


def _finish(flow: _Flow, result: dict) -> dict:
    flow.device_code = ""
    flow.result = result
    return result


def _failed(code: str, message: str, **extra) -> dict:
    return {"state": "failed", "code": code, "message": message, **extra}


def _received(token: str) -> dict:
    try:
        snapshot = github_token.validate_token(token)
        github_token.apply_token(token)
    except TokenError as exc:
        if exc.code == "org_approval_needed":
            return {"state": "org_approval_needed", "message": exc.message}
        return _failed(exc.code, exc.message, **({"missing_scopes": exc.missing_scopes} if exc.missing_scopes else {}))
    return {"state": "signed_in", **({"login": snapshot["login"]} if snapshot["login"] else {})}


def _answer(flow: _Flow, data: dict) -> dict | None:
    token, error = data.get("access_token"), data.get("error")
    if isinstance(token, str) and token:
        return _received(token)
    text = f"{error} {data.get('error_description', '')}".lower()
    if any(marker in text for marker in ORG_MARKERS):
        return {"state": "org_approval_needed", "message": _ORG_MESSAGE}
    if error == "authorization_pending":
        return None
    if error == "slow_down":
        flow.interval = min(int(data.get("interval") or flow.interval + SLOW_DOWN_SECONDS), MAX_INTERVAL_SECONDS)
        return None
    if error == "expired_token":
        return {"state": "expired", "message": "The sign-in code expired. Start again."}
    if error == "access_denied":
        return {"state": "denied", "message": "GitHub sign-in was cancelled."}
    if error in _REJECTED:
        return _failed("oauth_app_rejected", _REJECTED_MESSAGE)
    return _failed("failed", "GitHub sign-in didn't complete. Try again.")


def poll(session_id: str) -> dict:
    with _lock:
        flow = _current
        if flow is None or flow.session_id != session_id:
            return _failed("failed", "No GitHub sign-in is in progress.")
        if flow.result is not None:
            return flow.result
        now = _clock()
        if now >= flow.deadline:
            return _finish(flow, {"state": "expired", "message": "The sign-in code expired. Start again."})
        if now < flow.next_poll:
            return {"state": "pending"}
        try:
            data = _post(ACCESS_TOKEN_URL, {"client_id": flow.client_id, "device_code": flow.device_code,
                                            "grant_type": DEVICE_GRANT})
        except TokenError:
            flow.next_poll = now + flow.interval
            return {"state": "pending"}
        answered = _answer(flow, data)
        flow.next_poll = _clock() + flow.interval
        return {"state": "pending"} if answered is None else _finish(flow, answered)


def cancel(session_id: str) -> dict:
    global _current
    with _lock:
        if _current is not None and _current.session_id == session_id:
            _current = None
    return {"ok": True}


def cancel_all() -> None:
    global _current
    with _lock:
        _current = None


atexit.register(cancel_all)
