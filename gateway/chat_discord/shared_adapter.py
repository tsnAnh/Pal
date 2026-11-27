from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from hermes_constants import get_default_hermes_root
from tui_gateway.contracts.chat_provider import AdapterFailure, AdapterState, AdapterStatus

from .default_profile import ALLOWED_USERS_ENV, PLATFORM, ScopeFactory, default_profile_scope

BOT_TOKEN_ENV = "DISCORD_BOT_TOKEN"
CONNECT_WAIT_S = 45.0
POLL_S = 0.5

_FAILURE_FOR_CODE = {
    "discord_auth_error": AdapterFailure.invalid_token,
    "missing_credentials": AdapterFailure.invalid_token,
    "discord_intents_required": AdapterFailure.missing_intent,
    "adapter_unavailable": AdapterFailure.restart_needed,
    "missing_dependency": AdapterFailure.restart_needed,
}


@dataclass(frozen=True)
class Reading:
    state: str
    enabled: bool
    error_code: str | None
    updated_at: str | None


def failed(reason: AdapterFailure) -> AdapterStatus:
    return AdapterStatus(state=AdapterState.failed, reason=reason)


def status_of(reading: Reading) -> AdapterStatus:
    failure = _FAILURE_FOR_CODE.get(reading.error_code or "")
    match reading.state:
        case "connected":
            return AdapterStatus(state=AdapterState.online)
        case "connecting" | "retrying":
            return AdapterStatus(state=AdapterState.connecting, reason=failure)
        case "fatal" | "paused":
            return failed(failure or AdapterFailure.adapter_offline)
        case "gateway_stopped" | "startup_failed":
            return failed(AdapterFailure.restart_needed)
        case _:
            return AdapterStatus(state=AdapterState.not_started)


def gateway_reading() -> Reading:
    from hermes_cli.web_routers import messaging
    with default_profile_scope():
        payload = messaging._platform_payloads(get_default_hermes_root(), [messaging._require_platform(PLATFORM)])[0]
    return Reading(payload["state"], bool(payload["enabled"]), payload["error_code"], payload["updated_at"])


def reload_in_gateway() -> bool:
    from hermes_cli.gateway_multiplex_served import reload_platform_live
    return reload_platform_live(get_default_hermes_root(), PLATFORM, [BOT_TOKEN_ENV, ALLOWED_USERS_ENV])


def _written_since(reading: Reading, moment: datetime) -> bool:
    return reading.updated_at is not None and datetime.fromisoformat(reading.updated_at) >= moment


class SharedAdapter:
    def __init__(self, *, scope: ScopeFactory = default_profile_scope, read: Callable[[], Reading] = gateway_reading,
                 reload: Callable[[], bool] = reload_in_gateway, clock: Callable[[], float] = time.monotonic,
                 pause: Callable[[float], None] = time.sleep):
        self._scope, self._read, self._reload = scope, read, reload
        self._clock, self._pause = clock, pause

    def configure(self, token: str) -> bool:
        from hermes_cli.config import load_env
        from hermes_cli.web_routers import messaging
        enabled = self._read().enabled
        with self._scope():
            if enabled and load_env().get(BOT_TOKEN_ENV) == token:
                return False
            messaging._apply_platform_update(
                PLATFORM, messaging._require_platform(PLATFORM), messaging._env_value_rules(PLATFORM),
                {BOT_TOKEN_ENV: token}, [], True)
        return True

    def status(self) -> AdapterStatus:
        return status_of(self._read())

    def connect(self, *, changed: bool) -> AdapterStatus:
        if not changed and (current := self.status()).state is AdapterState.online:
            return current
        asked = datetime.now(UTC)
        if not self._reload():
            return failed(AdapterFailure.restart_needed)
        deadline = self._clock() + CONNECT_WAIT_S
        while True:
            reading = self._read()
            status = status_of(reading)
            settled = status.state in (AdapterState.online, AdapterState.failed)
            if settled and _written_since(reading, asked):
                return status
            if self._clock() >= deadline:
                break
            self._pause(POLL_S)
        if status.state is AdapterState.not_started:
            return failed(AdapterFailure.restart_needed)
        return failed(status.reason or AdapterFailure.adapter_offline)
