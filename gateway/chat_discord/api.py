from __future__ import annotations

import logging
import math
import time
from collections.abc import Callable
from typing import Any

import httpx

from tui_gateway.chat_install import FIX_FOR_ERROR
from tui_gateway.contracts.chat_provider import FixAction, SetupErrorCode

logger = logging.getLogger(__name__)

DISCORD_API = "https://discord.com/api/v10"
USER_AGENT = "DiscordBot (https://github.com/tsnAnh/Pal, 1)"
MAX_RATE_LIMIT_RETRIES = 1
MAX_RETRY_AFTER_S = 30.0

UNKNOWN_CHANNEL = 10003
UNKNOWN_GUILD = 10004
UNKNOWN_MEMBER = 10007
UNKNOWN_WEBHOOK = 10015
MISSING_ACCESS = 50001
MISSING_PERMISSIONS = 50013
INVALID_TOKEN = "invalid_token"
NO_TOKEN = "no_token"
BOT_NOT_IN_SERVER = "bot_not_in_server"
MISSING_INTENT = "missing_intent"
MISSING_PERMISSION = "missing_permission"
RATE_LIMITED = "rate_limited"
GONE_CODES = frozenset({UNKNOWN_CHANNEL, UNKNOWN_WEBHOOK})
NOT_IN_SERVER_CODES = frozenset({UNKNOWN_GUILD, UNKNOWN_MEMBER, MISSING_ACCESS})


class DiscordSetupError(Exception):
    def __init__(self, code: SetupErrorCode, reason: str | None = None, *, permissions: tuple[str, ...] = (),
                 retry_after_seconds: int | None = None, discord_code: int | None = None):
        super().__init__(f"discord setup failed: {code.value}" + (f" ({reason})" if reason else ""))
        self.code = code
        self.reason = reason
        self.permissions = permissions
        self.retry_after_seconds = retry_after_seconds
        self.discord_code = discord_code

    @property
    def fix(self) -> FixAction:
        return FIX_FOR_ERROR[self.code]


class DiscordGone(Exception):
    pass


def _retry_after(response: httpx.Response, body: Any) -> float:
    raw = body.get("retry_after") if isinstance(body, dict) else None
    if raw is None:
        raw = response.headers.get("Retry-After", "1")
    try:
        return min(max(float(raw), 0.0), MAX_RETRY_AFTER_S)
    except (TypeError, ValueError):
        return 1.0


def _json(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return None


def error_for(status: int, body: Any, *, permission: str | None = None) -> Exception:
    code = body.get("code") if isinstance(body, dict) and isinstance(body.get("code"), int) else None
    if status == 401:
        return DiscordSetupError(SetupErrorCode.credential_rejected, INVALID_TOKEN, discord_code=code)
    if code in NOT_IN_SERVER_CODES:
        return DiscordSetupError(SetupErrorCode.allow_denied, BOT_NOT_IN_SERVER, discord_code=code)
    if code == MISSING_PERMISSIONS:
        return DiscordSetupError(SetupErrorCode.install_failed, MISSING_PERMISSION,
                                 permissions=(permission,) if permission else (), discord_code=code)
    if code in GONE_CODES or status == 404:
        return DiscordGone()
    if status >= 500:
        return DiscordSetupError(SetupErrorCode.provider_unreachable, f"http_{status}", discord_code=code)
    return DiscordSetupError(SetupErrorCode.install_failed, f"http_{status}", discord_code=code)


class DiscordApi:
    def __init__(self, transport: httpx.BaseTransport | None = None, *,
                 sleep: Callable[[float], None] = time.sleep, timeout: float = 10.0):
        self._client = httpx.Client(base_url=DISCORD_API, transport=transport, follow_redirects=False,
                                    timeout=httpx.Timeout(timeout, connect=5.0))
        self._sleep = sleep

    def call(self, method: str, path: str, *, token: str, json: dict | None = None, params: dict | None = None,
             permission: str | None = None) -> Any:
        headers = {"Authorization": f"Bot {token}", "User-Agent": USER_AGENT, "Accept": "application/json"}
        for attempt in range(MAX_RATE_LIMIT_RETRIES + 1):
            response = self._send(method, path, headers, json, params)
            body = _json(response)
            if response.status_code != 429:
                return self._result(method, path, response, body, permission)
            wait = _retry_after(response, body)
            if attempt == MAX_RATE_LIMIT_RETRIES:
                logger.warning("discord %s %s rate limited", method, _route(path))
                raise DiscordSetupError(SetupErrorCode.provider_unreachable, RATE_LIMITED,
                                        retry_after_seconds=math.ceil(wait))
            self._sleep(wait)
        raise AssertionError("unreachable")

    def _send(self, method: str, path: str, headers: dict, json: dict | None, params: dict | None) -> httpx.Response:
        try:
            return self._client.request(method, path, headers=headers, json=json, params=params)
        except httpx.HTTPError:
            logger.warning("discord %s %s unreachable", method, _route(path))
            raise DiscordSetupError(SetupErrorCode.provider_unreachable, "network") from None

    @staticmethod
    def _result(method: str, path: str, response: httpx.Response, body: Any, permission: str | None) -> Any:
        if response.is_success:
            return body
        error = error_for(response.status_code, body, permission=permission)
        logger.info("discord %s %s failed: http %s", method, _route(path), response.status_code)
        raise error


def _route(path: str) -> str:
    return "/".join("{id}" if part.isdigit() else part for part in path.split("/"))
