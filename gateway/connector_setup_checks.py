from __future__ import annotations

import logging
import secrets
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

TIMEOUT_SECONDS = 10.0
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GITHUB_USER_URL = "https://api.github.com/user"
SLACK_USER_TOKEN_URL = "https://slack.com/api/oauth.v2.user.access"

default_transport: httpx.BaseTransport | None = None

FIELDS = {
    "google_client": ("client_id", "client_secret"),
    "github_token": ("token",),
    "slack_client": ("client_id", "client_secret"),
}


@dataclass(frozen=True)
class CheckOutcome:
    ok: bool
    reason: str | None = None
    message: str | None = None
    account: str | None = None


ACCEPTED = CheckOutcome(ok=True)
UNAVAILABLE = CheckOutcome(False, "check_unavailable", "Couldn't reach the service to test this. Try again.")
INVALID_CLIENT = CheckOutcome(False, "invalid_client", "The service didn't accept that client ID and secret.")
INVALID_TOKEN = CheckOutcome(False, "invalid_token", "GitHub didn't accept that token.")
NEEDS_PUBLIC_URL = CheckOutcome(False, "needs_public_url", "Set this gateway's public address first.")


def _json_object(response: httpx.Response) -> dict:
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def _google(client: httpx.Client, values: dict[str, str], redirect_url: str | None) -> CheckOutcome:
    if not redirect_url:
        return NEEDS_PUBLIC_URL
    response = client.post(GOOGLE_TOKEN_URL, data={
        "grant_type": "authorization_code", "code": secrets.token_urlsafe(24), "client_id": values["client_id"],
        "client_secret": values["client_secret"], "redirect_uri": redirect_url})
    error = _json_object(response).get("error")
    if error == "invalid_grant":
        return ACCEPTED
    if error in ("invalid_client", "unauthorized_client"):
        return INVALID_CLIENT
    return UNAVAILABLE


def _github(client: httpx.Client, values: dict[str, str], _redirect_url: str | None) -> CheckOutcome:
    response = client.get(GITHUB_USER_URL, headers={
        "Authorization": f"Bearer {values['token']}", "Accept": "application/vnd.github+json"})
    if response.status_code == 200:
        login = _json_object(response).get("login")
        return CheckOutcome(ok=True, account=login if isinstance(login, str) and login else None)
    if response.status_code in (401, 403):
        return INVALID_TOKEN
    return UNAVAILABLE


def _slack(client: httpx.Client, values: dict[str, str], _redirect_url: str | None) -> CheckOutcome:
    response = client.post(SLACK_USER_TOKEN_URL, data={
        "client_id": values["client_id"], "client_secret": values["client_secret"],
        "code": secrets.token_urlsafe(24)})
    error = _json_object(response).get("error")
    if error == "invalid_code":
        return ACCEPTED
    if error in ("invalid_client_id", "bad_client_secret"):
        return INVALID_CLIENT
    return UNAVAILABLE


_CHECKS = {"google_client": _google, "github_token": _github, "slack_client": _slack}


def run_check(kind: str, values: dict[str, str], *, redirect_url: str | None = None,
              transport: httpx.BaseTransport | None = None) -> CheckOutcome:
    """One provider call that proves pasted credentials work without completing a sign-in.

    Only the failure reason and exception type are logged: the values are secrets.
    """
    missing = [name for name in FIELDS[kind] if not values.get(name)]
    if missing:
        raise ValueError(f"missing {missing}")
    try:
        with httpx.Client(transport=transport or default_transport, timeout=TIMEOUT_SECONDS, follow_redirects=False) as client:
            outcome = _CHECKS[kind](client, values, redirect_url)
    except httpx.HTTPError as exc:
        logger.warning("connector setup check unavailable kind=%s error=%s", kind, type(exc).__name__)
        return UNAVAILABLE
    if not outcome.ok:
        logger.info("connector setup check rejected kind=%s reason=%s", kind, outcome.reason)
    return outcome
