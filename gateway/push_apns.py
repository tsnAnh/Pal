from __future__ import annotations

import json
import logging
import os
import random
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

import httpx

from gateway.device_registry import PushTarget

logger = logging.getLogger(__name__)

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
KEY_ENV = "APNS_AUTH_KEY"
KEY_PATH_ENV = "APNS_AUTH_KEY_PATH"
PROVIDER_TOKEN_SECONDS = 50 * 60
UNAVAILABLE_RETRY_SECONDS = 10 * 60
EXPIRATION_SECONDS = 60 * 60
REQUEST_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
MAX_ATTEMPTS = 3
BACKOFF_SECONDS = (0.5, 2.0)
REASON_LIMIT = 64
DEAD_TOKEN_REASONS = frozenset({"Unregistered", "BadDeviceToken"})


class _WithholdDeviceTokens(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return "/3/device/" not in record.getMessage()


def _keep_device_tokens_out_of_http_logs() -> None:
    http_logger = logging.getLogger("httpx")
    if not any(isinstance(item, _WithholdDeviceTokens) for item in http_logger.filters):
        http_logger.addFilter(_WithholdDeviceTokens())


class ApnsUnavailable(RuntimeError):
    pass


class Outcome(StrEnum):
    DELIVERED = "delivered"
    TOKEN_DEAD = "token_dead"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class ApnsConfig:
    key_id: str
    team_id: str
    topic: str
    private_key: str = ""


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def _install_secret(root: Path, name: str) -> str:
    from agent.secret_scope import load_env_file
    return _text(load_env_file(root / ".env").get(name)) or _text(os.environ.get(name))


def _private_key(root: Path) -> str:
    inline = _install_secret(root, KEY_ENV)
    if inline:
        return inline.replace("\\n", "\n")
    path = _install_secret(root, KEY_PATH_ENV)
    if not path:
        return ""
    try:
        return Path(path).expanduser().read_text(encoding="utf-8-sig").strip()
    except OSError as exc:
        logger.warning("The file named by %s is unreadable: %s", KEY_PATH_ENV, type(exc).__name__)
        return ""


def load_config(root) -> ApnsConfig | None:
    from hermes_cli.config_effective import load_user_config_effective
    root = Path(root)
    section = load_user_config_effective(root / "config.yaml").get("push")
    apns = section.get("apns") if isinstance(section, dict) else None
    if not isinstance(apns, dict):
        return None
    key_id, team_id = _text(apns.get("key_id")), _text(apns.get("team_id"))
    if not key_id or not team_id:
        return None
    private_key = _private_key(root)
    if not private_key:
        return None
    return ApnsConfig(key_id=key_id, team_id=team_id, topic=_text(apns.get("topic")), private_key=private_key)


def _reason(response: httpx.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        return ""
    reason = body.get("reason") if isinstance(body, dict) else None
    return "".join(ch for ch in reason if ch.isalnum())[:REASON_LIMIT] if isinstance(reason, str) else ""


class ApnsClient:
    def __init__(self, config: ApnsConfig, *, transport: httpx.BaseTransport | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.time):
        _keep_device_tokens_out_of_http_logs()
        self._config = config
        self._transport = transport
        self._sleep = sleep
        self._clock = clock
        self._lock = threading.Lock()
        self._http: dict[str, httpx.Client] = {}
        self._provider_token = ""
        self._provider_token_at = 0.0

    def close(self) -> None:
        with self._lock:
            clients, self._http = list(self._http.values()), {}
        for client in clients:
            client.close()

    def _client(self, environment: str) -> httpx.Client:
        with self._lock:
            client = self._http.get(environment)
            if client is None:
                client = httpx.Client(base_url=HOSTS[environment], http2=self._transport is None,
                                      transport=self._transport, timeout=REQUEST_TIMEOUT)
                self._http[environment] = client
            return client

    def _bearer(self, *, renew: bool = False) -> str:
        import jwt
        with self._lock:
            now = self._clock()
            if renew or not self._provider_token or now - self._provider_token_at >= PROVIDER_TOKEN_SECONDS:
                self._provider_token = jwt.encode(
                    {"iss": self._config.team_id, "iat": int(now)}, self._config.private_key,
                    algorithm="ES256", headers={"kid": self._config.key_id})
                self._provider_token_at = now
            return self._provider_token

    def _post(self, target: PushTarget, body: bytes, *, renew: bool) -> httpx.Response:
        topic = self._config.topic or target.bundle_id
        return self._client(target.environment).post(
            f"/3/device/{target.token}", content=body,
            headers={"authorization": f"bearer {self._bearer(renew=renew)}", "apns-topic": topic,
                     "apns-push-type": "alert", "apns-priority": "10",
                     "apns-expiration": str(int(self._clock()) + EXPIRATION_SECONDS),
                     "content-type": "application/json"})

    def send(self, target: PushTarget, payload: dict) -> Outcome:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        renew = False
        for attempt in range(MAX_ATTEMPTS):
            last = attempt == MAX_ATTEMPTS - 1
            try:
                response = self._post(target, body, renew=renew)
            except httpx.HTTPError as exc:
                logger.warning("APNs request for device %s failed: %s", target.device_id, type(exc).__name__)
                if last:
                    return Outcome.FAILED
                self._pause(attempt)
                continue
            renew = False
            status, reason = response.status_code, _reason(response)
            if status == 200:
                return Outcome.DELIVERED
            if status == 410 or reason in DEAD_TOKEN_REASONS:
                return Outcome.TOKEN_DEAD
            if status == 403 and reason == "ExpiredProviderToken" and not last:
                renew = True
                continue
            if (status == 429 or status >= 500) and not last:
                self._pause(attempt)
                continue
            logger.warning("APNs rejected the push for device %s: HTTP %s %s", target.device_id, status,
                           reason or "no reason")
            return Outcome.FAILED
        return Outcome.FAILED

    def _pause(self, attempt: int) -> None:
        base = BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
        self._sleep(base * (0.5 + random.random()))


_shared_lock = threading.Lock()
_shared: tuple[ApnsConfig, ApnsClient] | None = None
_retry_after = 0.0


def build_client(config: ApnsConfig) -> ApnsClient:
    import pm
    pm.ensure_import("apns")
    return ApnsClient(config)


def shared_client(config: ApnsConfig) -> ApnsClient:
    global _shared, _retry_after
    with _shared_lock:
        if _shared is not None and _shared[0] == config:
            return _shared[1]
        if time.monotonic() < _retry_after:
            raise ApnsUnavailable("APNs client setup failed recently")
        try:
            client = build_client(config)
        except Exception as exc:
            _retry_after = time.monotonic() + UNAVAILABLE_RETRY_SECONDS
            logger.warning("APNs client is unavailable (%s: %s); push is paused for %d minutes",
                           type(exc).__name__, exc, UNAVAILABLE_RETRY_SECONDS // 60)
            raise ApnsUnavailable(type(exc).__name__) from exc
        stale = _shared[1] if _shared is not None else None
        _shared = (config, client)
    if stale is not None:
        stale.close()
    return client
