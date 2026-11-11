"""GitHub OAuth device flow for the sign-in dialog (RFC 8628; client_id only, no secret).

The gateway host polls GitHub; the token goes straight to ``gh auth login --with-token`` on stdin, the
store the ``gh`` CLI and ``hermes_cli.github_api`` already read. It never reaches a log, an event or an
argument list.
"""
from __future__ import annotations

import logging
import subprocess
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional

import httpx

logger = logging.getLogger(__name__)

DEVICE_CODE_URL = "https://github.com/login/device/code"
ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device-code"
DEFAULT_SCOPE = "repo read:org workflow gist"
REQUEST_TIMEOUT_SECONDS = 15.0
GH_STORE_TIMEOUT_SECONDS = 30
MAX_INTERVAL_SECONDS = 30


class GithubSigninError(Exception):
    """A sign-in failure whose message is safe to log (never contains a token)."""


class NotConfigured(GithubSigninError):
    pass


class Cancelled(GithubSigninError):
    pass


@dataclass(frozen=True, slots=True)
class DeviceCode:
    device_code: str
    user_code: str
    verification_uri: str
    expires_in: int
    interval: int


def configured_client_id(home) -> str:
    from pathlib import Path

    from hermes_cli.config_effective import load_user_config_effective
    config = load_user_config_effective(Path(home) / "config.yaml")
    section = config.get("auth") if isinstance(config, dict) else None
    github = section.get("github") if isinstance(section, dict) else None
    value = github.get("client_id") if isinstance(github, dict) else None
    client_id = value.strip() if isinstance(value, str) else ""
    if not client_id:
        raise NotConfigured("auth.github.client_id is not set in config.yaml")
    return client_id


def request_device_code(client_id: str, *, post: Optional[Callable[..., Any]] = None,
                        scope: str = DEFAULT_SCOPE) -> DeviceCode:
    post = post or _post
    try:
        data = post(DEVICE_CODE_URL, {"client_id": client_id, "scope": scope})
        return DeviceCode(device_code=str(data["device_code"]), user_code=str(data["user_code"]),
                          verification_uri=str(data["verification_uri"]), expires_in=int(data["expires_in"]),
                          interval=max(1, int(data.get("interval", 5))))
    except (KeyError, TypeError, ValueError) as exc:
        raise GithubSigninError("GitHub returned an unusable device code") from exc
    except httpx.HTTPError as exc:
        raise GithubSigninError(f"GitHub device code request failed ({type(exc).__name__})") from exc


def poll_for_token(client_id: str, code: DeviceCode, *, post: Optional[Callable[..., Any]] = None,
                   sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                   cancelled: Callable[[], bool] = lambda: False) -> str:
    post = post or _post
    deadline = clock() + code.expires_in
    interval = min(code.interval, MAX_INTERVAL_SECONDS)
    while clock() < deadline:
        if cancelled():
            raise Cancelled("sign-in cancelled")
        try:
            data = post(ACCESS_TOKEN_URL, {"client_id": client_id, "device_code": code.device_code,
                                           "grant_type": DEVICE_GRANT})
        except httpx.HTTPError:
            data = {"error": "authorization_pending"}
        token = data.get("access_token") if isinstance(data, dict) else None
        if isinstance(token, str) and token:
            return token
        error = data.get("error") if isinstance(data, dict) else None
        if error == "slow_down":
            interval = min(interval + 5, MAX_INTERVAL_SECONDS)
        elif error in ("expired_token", "access_denied", "unsupported_grant_type", "incorrect_client_credentials",
                       "incorrect_device_code", "device_flow_disabled"):
            raise GithubSigninError(f"GitHub ended the sign-in ({error})")
        sleep(interval)
    raise GithubSigninError("the GitHub device code expired")


def store_token_with_gh(token: str, *, run: Optional[Callable[..., Any]] = None) -> None:
    run = run or subprocess.run
    from hermes_cli._subprocess_compat import windows_hide_flags
    try:
        result = run(["gh", "auth", "login", "--hostname", "github.com", "--with-token"], input=token,
                     capture_output=True, text=True, timeout=GH_STORE_TIMEOUT_SECONDS, check=False,
                     creationflags=windows_hide_flags())
    except (OSError, subprocess.SubprocessError) as exc:
        raise GithubSigninError(f"could not run gh to store the login ({type(exc).__name__})") from exc
    if result.returncode != 0:
        raise GithubSigninError("gh did not accept the new login")
    from hermes_cli import github_api
    github_api._gh_cli_cache, github_api._gh_cli_probed = None, False


def _post(url: str, form: dict) -> dict:
    response = httpx.post(url, data=form, headers={"Accept": "application/json"}, timeout=REQUEST_TIMEOUT_SECONDS)
    response.raise_for_status()
    body = response.json()
    return body if isinstance(body, dict) else {}
