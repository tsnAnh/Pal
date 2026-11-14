from __future__ import annotations

import asyncio
import concurrent.futures
import json
import logging
import time
import uuid
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ValidationError

from gateway import device_connectors
from gateway.device_actions import ActionSpec, clean_text, fit_result
from gateway.reach_presence import DEVICE_TOOL_KINDS, Attention, ClientKind, attention_of, last_frame_at, slot_of
from tui_gateway.contracts.canonical_device import (
    DeviceConnectorState as ConnectorState,
    DeviceOsPermission,
    DeviceToolCancelPayload,
    DeviceToolCancelReason,
    DeviceToolErrorCode,
    DeviceToolRequestPayload,
)
from tui_gateway.device_frames import cancel_frame, request_frame

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_CONSENT_TIMEOUT_SECONDS = 120.0
MIN_TIMEOUT_SECONDS = 5.0
MAX_TIMEOUT_SECONDS = 300.0
MAX_RESULT_BYTES = 128 * 1024
MAX_TRUNCATABLE_RAW_BYTES = 4 * 1024 * 1024
PHONE_KINDS = DEVICE_TOOL_KINDS
DEVICE_KINDS = DEVICE_TOOL_KINDS
THREAD_WAIT_MARGIN_SECONDS = 10.0


class Failure(StrEnum):
    CONNECTOR_OFF = "connector_off"
    PHONE_OFFLINE = "phone_offline"
    TIMEOUT = "timeout"
    DISCONNECTED = "disconnected"
    PERMISSION_DENIED = "permission_denied"
    CONSENT_DECLINED = "consent_declined"
    UNSUPPORTED = "unsupported"
    INVALID_ARGS = "invalid_args"
    NOT_FOUND = "not_found"
    DEVICE_FAILED = "device_failed"
    INVALID_RESULT = "invalid_result"
    UNAVAILABLE = "unavailable"


_DEVICE_ERRORS = {
    DeviceToolErrorCode.PERMISSION_DENIED: Failure.PERMISSION_DENIED,
    DeviceToolErrorCode.CONSENT_DECLINED: Failure.CONSENT_DECLINED,
    DeviceToolErrorCode.UNSUPPORTED: Failure.UNSUPPORTED,
    DeviceToolErrorCode.INVALID_ARGS: Failure.INVALID_ARGS,
    DeviceToolErrorCode.NOT_FOUND: Failure.NOT_FOUND,
    DeviceToolErrorCode.FAILED: Failure.DEVICE_FAILED,
}

@dataclass(frozen=True, slots=True)
class Outcome:
    data: dict | None = None
    failure: Failure | None = None
    detail: str = ""
    device: str = ""

    @property
    def ok(self) -> bool:
        return self.failure is None


@dataclass(frozen=True, slots=True)
class Timeouts:
    request: float = DEFAULT_TIMEOUT_SECONDS
    consent: float = DEFAULT_CONSENT_TIMEOUT_SECONDS


@dataclass(frozen=True, slots=True)
class _Route:
    transport: Any
    device_id: str
    state: ConnectorState
    rank: tuple
    label: str = ""


@dataclass(slots=True)
class _Pending:
    future: asyncio.Future
    authority: Any
    transport: Any
    home: Path
    spec: ActionSpec
    device_id: str
    label: str = ""


_pending: dict[str, _Pending] = {}


def _bounded(value: Any, default: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return min(max(float(value), MIN_TIMEOUT_SECONDS), MAX_TIMEOUT_SECONDS)


def settings(home: Path) -> Timeouts:
    from hermes_cli.config_effective import load_user_config_effective
    section = load_user_config_effective(Path(home) / "config.yaml").get("iphone")
    section = section if isinstance(section, dict) else {}
    return Timeouts(_bounded(section.get("timeout_seconds"), DEFAULT_TIMEOUT_SECONDS),
                    _bounded(section.get("consent_timeout_seconds"), DEFAULT_CONSENT_TIMEOUT_SECONDS))


def live_slots(authority, now: float, kinds: frozenset = DEVICE_KINDS,
               device_id: str | None = None) -> list[tuple[Any, Any, Attention]]:
    found = []
    for transport in list(authority.events.values()):
        slot = slot_of(transport)
        if slot is None or not slot.device_tools or slot.device.kind not in kinds:
            continue
        if device_id is not None and slot.device.device_id != device_id:
            continue
        attention = attention_of(slot, last_frame=last_frame_at(transport), now=now)
        if attention is not Attention.PARKED:
            found.append((transport, slot, attention))
    return found


def route_rank(slot, attention: Attention) -> tuple:
    return (int(attention), slot.last_input_at or 0.0, slot.attention_at)


def live_device_ids(authority, now: float, kinds: frozenset = DEVICE_KINDS) -> set[str]:
    return {slot.device.device_id for _, slot, _ in live_slots(authority, now, kinds)}


def _routes(authority, states: dict[str, ConnectorState], now: float, *, kinds: frozenset = PHONE_KINDS,
            device_id: str | None = None) -> list[_Route]:
    found = []
    for transport, slot, attention in live_slots(authority, now, kinds, device_id):
        state = states.get(slot.device.device_id)
        if state is not None:
            found.append(_Route(transport, slot.device.device_id, state, route_rank(slot, attention),
                                slot.device.label))
    return sorted(found, key=lambda route: route.rank, reverse=True)


def _profile_name(home: Path) -> str:
    from hermes_constants import profile_name_for_home
    return profile_name_for_home(home) or "default"


def _withdraw(request_id: str, route: _Route, reason: DeviceToolCancelReason) -> None:
    frame = cancel_frame(DeviceToolCancelPayload(request_id=request_id, reason=reason))
    asyncio.get_running_loop().run_in_executor(None, route.transport.write, frame)


async def round_trip(authority, home: Path, spec: ActionSpec, args: BaseModel, *, session_id: str | None,
                     timeouts: Timeouts, device_id: str | None = None) -> Outcome:
    states = await asyncio.to_thread(device_connectors.open_devices, home, spec.connector)
    if device_id is not None:
        states = {key: value for key, value in states.items() if key == device_id}
    if not states:
        return Outcome(failure=Failure.CONNECTOR_OFF)
    kinds = frozenset(ClientKind(kind) for kind in spec.kinds) if device_id is not None else PHONE_KINDS
    routes = _routes(authority, states, time.time(), kinds=kinds, device_id=device_id)
    if not routes:
        return Outcome(failure=Failure.PHONE_OFFLINE)
    route = routes[0]
    needs_consent = route.state is ConnectorState.ASK
    deadline = timeouts.consent if needs_consent else timeouts.request
    request_id = uuid.uuid4().hex
    pending = _Pending(asyncio.get_running_loop().create_future(), authority, route.transport, home, spec,
                       route.device_id, route.label)
    _pending[request_id] = pending
    frame = request_frame(DeviceToolRequestPayload(
        request_id=request_id, action=spec.name, connector=spec.connector,
        args=args.model_dump(mode="json", exclude_none=True), needs_consent=needs_consent,
        profile=_profile_name(home), session_id=session_id or None, deadline_seconds=int(deadline)))
    try:
        if not await asyncio.to_thread(route.transport.write, frame):
            return Outcome(failure=Failure.PHONE_OFFLINE)
        try:
            return await asyncio.wait_for(pending.future, deadline)
        except TimeoutError:
            _withdraw(request_id, route, DeviceToolCancelReason.TIMEOUT)
            return Outcome(failure=Failure.TIMEOUT, device=route.label)
    except asyncio.CancelledError:
        _withdraw(request_id, route, DeviceToolCancelReason.INTERRUPTED)
        raise
    finally:
        _pending.pop(request_id, None)


def _settle(pending: _Pending, outcome: Outcome) -> bool:
    if pending.future.done():
        return False
    pending.future.set_result(outcome)
    return True


def _interpret_result(spec: ActionSpec, result: Any) -> Outcome:
    if not isinstance(result, dict):
        return Outcome(failure=Failure.INVALID_RESULT, detail="the phone sent a result that is not an object")
    allowed = spec.max_result_bytes or (MAX_TRUNCATABLE_RAW_BYTES if spec.truncates else MAX_RESULT_BYTES)
    if len(json.dumps(result, ensure_ascii=False)) > allowed:
        return Outcome(failure=Failure.INVALID_RESULT, detail="the phone sent more data than allowed")
    try:
        parsed = spec.result.model_validate(result)
    except ValidationError as exc:
        fields = ", ".join(sorted({".".join(str(part) for part in err["loc"]) for err in exc.errors()}))[:200]
        return Outcome(failure=Failure.INVALID_RESULT, detail=f"the phone sent a result that does not match ({fields})")
    data = parsed.model_dump(mode="json", exclude_none=True)
    if spec.truncates:
        data = fit_result(data, MAX_RESULT_BYTES)
        if len(json.dumps(data, ensure_ascii=False)) > MAX_RESULT_BYTES:
            return Outcome(failure=Failure.INVALID_RESULT, detail="the device sent more data than allowed")
    return Outcome(data=data)


async def respond(authority, transport, request_id: str, *, ok: bool, result: Any,
                  error_code: DeviceToolErrorCode | None, error_message: str) -> bool:
    pending = _pending.get(request_id)
    if pending is None or pending.authority is not authority or pending.transport is not transport:
        return False
    if ok:
        outcome = await asyncio.to_thread(_interpret_result, pending.spec, result)
    else:
        failure = _DEVICE_ERRORS.get(error_code or DeviceToolErrorCode.FAILED, Failure.DEVICE_FAILED)
        outcome = Outcome(failure=failure, detail=clean_text(error_message, 200), device=pending.label)
    if not _settle(pending, outcome):
        return False
    if outcome.failure is Failure.PERMISSION_DENIED:
        try:
            await asyncio.to_thread(device_connectors.update, pending.home, pending.device_id,
                                    pending.spec.connector, os_permission=DeviceOsPermission.DENIED)
        except (device_connectors.StoreUnreadable, device_connectors.UnknownDevice):
            logger.warning("Could not record the iPhone's denied %s permission", pending.spec.connector.value,
                           exc_info=True)
    return True


def forget_transport(transport) -> int:
    from gateway import device_mcp_relay
    dropped = [pending for pending in _pending.values() if pending.transport is transport]
    for pending in dropped:
        _settle(pending, Outcome(failure=Failure.DISCONNECTED, device=pending.label))
    return len(dropped) + device_mcp_relay.forget_transport(transport)


def preflight(home: Path, spec: ActionSpec) -> Outcome | None:
    from gateway.session_cron import owner_for_home
    states = device_connectors.open_devices(home, spec.connector)
    if not states:
        return Outcome(failure=Failure.CONNECTOR_OFF)
    bound = owner_for_home(home)
    if bound is None:
        return Outcome(failure=Failure.UNAVAILABLE)
    return None if _routes(bound[0], states, time.time()) else Outcome(failure=Failure.PHONE_OFFLINE)


def call_from_thread(home: Path, spec: ActionSpec, args: BaseModel, *, session_id: str | None,
                     timeouts: Timeouts, device_id: str | None = None) -> Outcome:
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        return Outcome(failure=Failure.UNAVAILABLE)
    authority, loop = bound
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        return Outcome(failure=Failure.UNAVAILABLE)
    future = asyncio.run_coroutine_threadsafe(
        round_trip(authority, home, spec, args, session_id=session_id, timeouts=timeouts, device_id=device_id), loop)
    wait = max(timeouts.request, timeouts.consent) + THREAD_WAIT_MARGIN_SECONDS
    try:
        return future.result(wait)
    except concurrent.futures.TimeoutError:
        future.cancel()
        return Outcome(failure=Failure.TIMEOUT)
    except BaseException:
        future.cancel()
        raise
