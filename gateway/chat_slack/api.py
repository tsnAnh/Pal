from __future__ import annotations

import logging
import time
from typing import Any, Callable

import httpx

from tui_gateway.chat_install import FIX_FOR_ERROR
from tui_gateway.contracts.chat_provider import FixAction, SetupErrorCode

logger = logging.getLogger(__name__)

SLACK_API = "https://slack.com/api/"
MAX_RATE_LIMIT_WAITS = 2
MAX_RETRY_AFTER_S = 60.0

ERROR_CODES: dict[str, SetupErrorCode] = {
    "invalid_auth": SetupErrorCode.credential_rejected,
    "not_authed": SetupErrorCode.credential_rejected,
    "token_revoked": SetupErrorCode.credential_rejected,
    "account_inactive": SetupErrorCode.credential_rejected,
    "token_expired": SetupErrorCode.credential_expired,
    "invalid_refresh_token": SetupErrorCode.credential_expired,
    "ratelimited": SetupErrorCode.provider_unreachable,
    "network_failure": SetupErrorCode.provider_unreachable,
    "name_taken": SetupErrorCode.app_create_failed,
    "invalid_manifest": SetupErrorCode.app_create_failed,
    "app_not_found": SetupErrorCode.app_create_failed,
    "missing_scope": SetupErrorCode.install_failed,
    "access_denied": SetupErrorCode.allow_denied,
    "invalid_code": SetupErrorCode.allow_denied,
    "code_already_used": SetupErrorCode.allow_denied,
}


class SlackSetupError(Exception):
    def __init__(self, code: SetupErrorCode, slack_error: str = "", *,
                 retry_after: float | None = None, app_id: str | None = None):
        super().__init__(f"slack setup failed: {code.value}" + (f" (app {app_id})" if app_id else ""))
        self.code = code
        self.slack_error = slack_error
        self.retry_after = retry_after
        self.app_id = app_id

    @property
    def fix(self) -> FixAction:
        return FIX_FOR_ERROR[self.code]


def error_for(slack_error: str, *, retry_after: float | None = None) -> SlackSetupError:
    return SlackSetupError(ERROR_CODES.get(slack_error, SetupErrorCode.install_failed), slack_error,
                           retry_after=retry_after)


def _retry_after(response: httpx.Response) -> float:
    try:
        return min(max(float(response.headers.get("Retry-After", "1")), 0.0), MAX_RETRY_AFTER_S)
    except ValueError:
        return 1.0


class SlackApi:
    def __init__(self, transport: httpx.BaseTransport | None = None, *,
                 sleep: Callable[[float], None] = time.sleep, timeout: float = 20.0):
        self._client = httpx.Client(base_url=SLACK_API, transport=transport, timeout=timeout)
        self._sleep = sleep

    def call(self, method: str, *, token: str | None = None, json: dict | None = None,
             data: dict | None = None, files: dict | None = None, raw: bool = False) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        for attempt in range(MAX_RATE_LIMIT_WAITS + 1):
            response = self._send(method, headers, json, data, files)
            if response.status_code != 429:
                return self._parse(method, response, raw)
            wait = _retry_after(response)
            if attempt == MAX_RATE_LIMIT_WAITS:
                logger.warning("slack %s rate limited", method)
                raise error_for("ratelimited", retry_after=wait)
            self._sleep(wait)
        raise AssertionError("unreachable")

    def _send(self, method, headers, json, data, files) -> httpx.Response:
        try:
            return self._client.post(method, headers=headers, json=json, data=data, files=files)
        except httpx.HTTPError:
            logger.warning("slack %s unreachable", method)
            raise error_for("network_failure") from None

    @staticmethod
    def _parse(method: str, response: httpx.Response, raw: bool = False) -> dict[str, Any]:
        try:
            body = response.json()
        except ValueError:
            body = None
        if not isinstance(body, dict):
            logger.warning("slack %s returned http %s", method, response.status_code)
            raise error_for("network_failure") from None
        if not body.get("ok") and not raw:
            error = str(body.get("error") or "")
            logger.info("slack %s failed: %s", method, ERROR_CODES.get(error, SetupErrorCode.install_failed).value)
            raise error_for(error)
        return body
