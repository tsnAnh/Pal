"""The host's single GitHub token: status for ``github.token.status`` and the apply step of the OAuth flow.

One ``gh`` login serves every profile and bot on the host. A new token is checked against the GitHub API in
memory, then handed to ``gh auth login --with-token`` on stdin. Status is read through ``gh`` itself
(``gh api user -i``), so this process never reads the token, ``gh auth token`` or gh's credential files.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime

import httpx

HOST = "github.com"
API_USER_URL = "https://api.github.com/user"
REQUIRED_SCOPES = ("repo", "workflow", "read:org", "gist")
HTTP_TIMEOUT_SECONDS = 10.0
COMMAND_TIMEOUT_SECONDS = 15.0
MAX_BODY_BYTES = 65536

_TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
_STATUS_LINE = re.compile(r"^HTTP/\S+\s+(\d{3})")
_EXPIRY_FORMAT = "%Y-%m-%d %H:%M:%S %Z"


class TokenError(Exception):
    def __init__(self, code: str, message: str, missing_scopes: list[str] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.missing_scopes = missing_scopes or []


@dataclass(frozen=True)
class Probe:
    status: int
    scopes: str | None = None
    expiry: str | None = None
    login: str | None = None
    message: str | None = None


def host_env() -> dict[str, str]:
    """The host user's normal terminal environment: reuses the terminal tool's builder, so the Bot Desktop's
    XDG overrides stay out, then drops any token variable so gh answers from its own store only."""
    from tools.environments.local import _make_run_env
    env = _make_run_env({})
    for name in _TOKEN_VARS:
        env.pop(name, None)
    return env


def _parse_expiry(raw: str | None) -> datetime | None:
    try:
        return datetime.strptime(raw.strip(), _EXPIRY_FORMAT).replace(tzinfo=UTC) if raw else None
    except ValueError:
        return None


def _snapshot(state: str, **fields) -> dict:
    return {"state": state, "login": None, "scopes": [], "missing_scopes": [], "expires_at": None,
            "token_kind": "unknown", "git_protocol": "unset", **fields}


def _classify(probe: Probe) -> dict:
    expires = _parse_expiry(probe.expiry)
    expires_at = expires.strftime("%Y-%m-%dT%H:%M:%SZ") if expires else None
    expired = expires is not None and expires <= datetime.now(UTC)
    if probe.status == 401:
        return _snapshot("expired" if expired else "invalid", expires_at=expires_at)
    if probe.status != 200:
        return _snapshot("unknown", expires_at=expires_at)
    if expired:
        return _snapshot("expired", login=probe.login, expires_at=expires_at)
    if probe.scopes is None:
        return _snapshot("set", login=probe.login, expires_at=expires_at, token_kind="fine_grained")
    scopes = [s.strip() for s in probe.scopes.split(",") if s.strip()]
    missing = [s for s in REQUIRED_SCOPES if s not in scopes]
    return _snapshot("missing_scopes" if missing else "set", login=probe.login, scopes=scopes,
                     missing_scopes=missing, expires_at=expires_at, token_kind="classic")


def _fetch_user(token: str) -> Probe:
    try:
        response = httpx.get(API_USER_URL, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "User-Agent": "hermes-agent"})
    except httpx.HTTPError:
        raise TokenError("unreachable", "Couldn't reach GitHub to check the token. Check the connection and try again.") from None
    try:
        body = response.json()
    except ValueError:
        body = None
    body = body if isinstance(body, dict) else {}
    login, message = body.get("login"), body.get("message")
    return Probe(response.status_code, response.headers.get("X-OAuth-Scopes"),
                 response.headers.get("github-authentication-token-expiration"),
                 login if isinstance(login, str) else None, message if isinstance(message, str) else None)


def _run(argv: list[str], stdin: str | None = None) -> tuple[int, str] | None:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=COMMAND_TIMEOUT_SECONDS,
                              input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                              env=host_env(), check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.returncode, f"{done.stdout}\n{done.stderr}"


def _parse_gh_api(output: str) -> Probe | None:
    head, _, body = output.lstrip().partition("\n\n")
    lines = head.splitlines()
    match = _STATUS_LINE.match(lines[0]) if lines else None
    if match is None:
        return None
    headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
    try:
        login = json.loads(body.strip().split("\n", 1)[0] or "{}").get("login")
    except (ValueError, AttributeError):
        login = None
    return Probe(int(match.group(1)), headers.get("x-oauth-scopes"),
                 headers.get("github-authentication-token-expiration"), login if isinstance(login, str) else None)


def configured_client_id() -> str | None:
    from hermes_cli.config import load_config
    section = load_config().get("auth")
    github = section.get("github") if isinstance(section, dict) else None
    value = github.get("client_id") if isinstance(github, dict) else None
    return value.strip() or None if isinstance(value, str) else None


def _git_protocol() -> str:
    done = _run(["gh", "config", "get", "git_protocol", "-h", HOST])
    value = done[1].strip().lower() if done is not None and done[0] == 0 else ""
    return value if value in ("https", "ssh") else "unset"


def _stored_state() -> dict:
    done = _run(["gh", "api", "user", "-i", "--hostname", HOST])
    if done is None:
        return _snapshot("unknown")
    probe = _parse_gh_api(done[1])
    if probe is not None:
        return _classify(probe)
    return _snapshot("missing" if "gh auth login" in done[1] else "unknown")


def github_token_state() -> dict:
    """The ``github.token.status`` shape; never raises and never carries the token."""
    state = _stored_state()
    if state["state"] == "missing" and configured_client_id() is None:
        state = _snapshot("oauth_app_not_configured")
    return {**state, "git_protocol": _git_protocol()}


def validate_token(token: str) -> dict:
    probe = _fetch_user(token)
    snapshot = _classify(probe)
    state = snapshot["state"]
    if probe.status == 403 and "access restrictions" in (probe.message or "").lower():
        raise TokenError("org_approval_needed", "An organization restricts third-party apps. An organization owner must approve Pal.")
    if state == "expired":
        raise TokenError("expired", "This token has expired.")
    if state == "invalid":
        raise TokenError("invalid", "GitHub didn't accept the token.")
    if state == "unknown":
        raise TokenError("unreachable", "GitHub didn't answer as expected. Try again in a moment.")
    if state == "missing_scopes":
        raise TokenError("missing_scopes", "Pal's GitHub app is missing permissions bots need: "
                         + ", ".join(snapshot["missing_scopes"]) + ".", snapshot["missing_scopes"])
    return snapshot


def apply_token(token: str) -> None:
    for argv in (["gh", "auth", "setup-git", "--hostname", HOST, "--force"],
                 ["gh", "config", "set", "git_protocol", "https"],
                 ["gh", "config", "set", "git_protocol", "https", "-h", HOST]):
        done = _run(argv)
        if done is None or done[0] != 0:
            raise TokenError("apply_failed", "Couldn't set git up to use HTTPS on this computer.")
    done = _run(["gh", "auth", "login", "--hostname", HOST, "--with-token"], stdin=f"{token}\n")
    if done is None or done[0] != 0:
        raise TokenError("apply_failed", "GitHub's command-line tool couldn't save the token on this computer.")
