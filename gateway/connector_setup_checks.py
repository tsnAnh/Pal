from __future__ import annotations

import base64
import logging
import re
import secrets
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

TIMEOUT_SECONDS = 10.0
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GITHUB_USER_URL = "https://api.github.com/user"
CANVA_TOKEN_URL = "https://api.canva.com/rest/v1/oauth/token"
DISCORD_API = "https://discord.com/api/v10"
DISCORD_TOKEN_SHAPE = re.compile(r"^[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{20,}$")

default_transport: httpx.BaseTransport | None = None

FIELDS = {
    "google_client": ("client_id", "client_secret"),
    "github_token": ("token",),
    "canva_client": ("client_id", "client_secret"),
    "discord_bot": ("token",),
}

REDIRECT_TEMPLATE = {"canva_client": "mcp_redirect_url"}


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
INVALID_DISCORD_TOKEN = CheckOutcome(False, "invalid_token", "Discord didn't accept that bot token.")
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


def _canva(client: httpx.Client, values: dict[str, str], redirect_url: str | None) -> CheckOutcome:
    if not redirect_url:
        return NEEDS_PUBLIC_URL
    basic = base64.b64encode(f"{values['client_id']}:{values['client_secret']}".encode()).decode()
    response = client.post(CANVA_TOKEN_URL, headers={"Authorization": f"Basic {basic}"}, data={
        "grant_type": "authorization_code", "code": secrets.token_urlsafe(24),
        "code_verifier": secrets.token_urlsafe(48), "redirect_uri": redirect_url})
    if response.status_code == 400 and _json_object(response).get("error") == "invalid_grant":
        return ACCEPTED
    if response.status_code == 401:
        return INVALID_CLIENT
    return UNAVAILABLE


@dataclass(frozen=True)
class DiscordBot:
    id: str
    name: str


def discord_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bot {token}", "Accept": "application/json"}


def discord_bot(client: httpx.Client, token: str) -> DiscordBot | CheckOutcome:
    if not DISCORD_TOKEN_SHAPE.match(token):
        return INVALID_DISCORD_TOKEN
    response = client.get(f"{DISCORD_API}/users/@me", headers=discord_headers(token))
    if response.status_code in (401, 403):
        return INVALID_DISCORD_TOKEN
    body = _json_object(response)
    bot_id, name = body.get("id"), body.get("global_name") or body.get("username")
    if response.status_code != 200 or not isinstance(bot_id, str) or not bot_id.isdigit() or body.get("bot") is not True:
        return INVALID_DISCORD_TOKEN if response.status_code == 200 else UNAVAILABLE
    return DiscordBot(id=bot_id, name=name if isinstance(name, str) and name else bot_id)


def _discord(client: httpx.Client, values: dict[str, str], _redirect_url: str | None) -> CheckOutcome:
    bot = discord_bot(client, values["token"])
    return bot if isinstance(bot, CheckOutcome) else CheckOutcome(ok=True, account=bot.name)


_CHECKS = {"google_client": _google, "github_token": _github, "canva_client": _canva, "discord_bot": _discord}


def run_check(kind: str, values: dict[str, str], *, redirect_url: str | None = None,
              transport: httpx.BaseTransport | None = None) -> CheckOutcome:
    # Only the failure reason and exception type are logged: the values are secrets.
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
