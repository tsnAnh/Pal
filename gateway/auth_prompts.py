from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import time
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any

from gateway import auth_flows
from gateway.reach_presence import PUSH_CLIENT_KINDS, Attention, attention_of, last_frame_at, slot_of
from tools.auth_required import AuthNeed, service_display_name
from tui_gateway.auth_frames import required_frame, resolved_frame
from tui_gateway.contracts.canonical_auth import AuthRequiredPayload, AuthResolvedPayload

logger = logging.getLogger(__name__)

SIGNIN_TIMEOUT_SECONDS = 300.0
DECLINE_COOLDOWN_SECONDS = 60.0
THREAD_WAIT_MARGIN_SECONDS = 10.0


class Resolution(StrEnum):
    SIGNED_IN = "signed_in"
    FAILED = "failed"
    DECLINED = "declined"
    TIMED_OUT = "timed_out"
    NO_APP = "no_app"
    UNAVAILABLE = "unavailable"


class CredentialOutcome(StrEnum):
    STORED = "stored"
    FAILED = "failed"
    REJECTED = "rejected"


@dataclass(eq=False)
class _Request:
    request_id: str
    key: tuple
    home: Path
    authority: Any
    service: str
    reason: str
    flow: Any
    bots: list[str]
    transports: list = field(default_factory=list)
    future: asyncio.Future = field(default_factory=lambda: asyncio.get_running_loop().create_future())
    driver: asyncio.Task | None = None
    signin_acknowledged: bool = False
    authorize_url: str | None = None
    concluding: bool = False
    answering: bool = False


_active: dict[tuple, _Request] = {}
_by_id: dict[str, _Request] = {}
_declined_until: dict[tuple, float] = {}


def _key(home: Path, service: str) -> tuple:
    return (str(Path(home).resolve()), service)


def _routes(authority) -> list:
    now = time.time()
    found = []
    for transport in list(authority.events.values()):
        slot = slot_of(transport)
        if slot is None or slot.device.kind not in PUSH_CLIENT_KINDS or not slot.accepts_offers:
            continue
        if attention_of(slot, last_frame=last_frame_at(transport), now=now) is Attention.PARKED:
            continue
        found.append(transport)
    return found


def _required_frame(req: _Request) -> dict:
    return required_frame(AuthRequiredPayload(
        request_id=req.request_id, service=req.service, service_name=service_display_name(req.service),
        bot=req.bots[0], bots=list(req.bots), reason=req.reason, flow=req.flow.kind,
        user_code=req.flow.user_code, verification_uri=req.flow.verification_uri, expires_in=req.flow.expires_in,
        server=getattr(req.flow, 'server', None), signin_on=getattr(req.flow, 'signin_on', None)))


async def _broadcast(transports: list, frame: dict) -> list:
    delivered = []
    for transport in transports:
        try:
            if await asyncio.to_thread(transport.write, frame):
                delivered.append(transport)
        except Exception:
            logger.debug("auth prompt write failed", exc_info=True)
    return delivered


def _finish(req: _Request, resolution: Resolution) -> None:
    if _active.get(req.key) is req:
        del _active[req.key]
    _by_id.pop(req.request_id, None)
    if resolution is Resolution.DECLINED:
        _declined_until[req.key] = time.monotonic() + DECLINE_COOLDOWN_SECONDS
    if not req.future.done():
        req.future.set_result(resolution)


async def _drive(req: _Request) -> None:
    try:
        signed_in = await asyncio.wait_for(req.flow.wait(), SIGNIN_TIMEOUT_SECONDS)
        resolution = Resolution.SIGNED_IN if signed_in else Resolution.FAILED
    except TimeoutError:
        resolution = Resolution.TIMED_OUT
    except Exception:
        logger.warning("sign-in flow for %s crashed", req.service, exc_info=True)
        resolution = Resolution.FAILED
    await _conclude(req, resolution)


async def _conclude(req: _Request, resolution: Resolution) -> None:
    if req.future.done() or req.concluding:
        return
    req.concluding = True
    if resolution is not Resolution.SIGNED_IN:
        req.flow.cancel()
    wire = {Resolution.SIGNED_IN: "signed_in", Resolution.DECLINED: "declined",
            Resolution.TIMED_OUT: "timed_out"}.get(resolution, "failed")
    reason = None if resolution is Resolution.SIGNED_IN else getattr(req.flow, "failure", None)
    await _broadcast(list(req.transports),
                     resolved_frame(AuthResolvedPayload(request_id=req.request_id, outcome=wire, reason=reason)))
    _finish(req, resolution)


async def request_signin(authority, home: Path, need: AuthNeed, bot: str) -> Resolution:
    key = _key(home, need.service)
    cooldown = _declined_until.get(key)
    if cooldown is not None:
        if time.monotonic() < cooldown:
            return Resolution.DECLINED
        del _declined_until[key]
    existing = _active.get(key)
    if existing is not None:
        if bot not in existing.bots:
            existing.bots.append(bot)
            await _broadcast(list(existing.transports), _required_frame(existing))
        return await asyncio.shield(existing.future)
    opened = await _open(authority, home, need, bot, key)
    if isinstance(opened, Resolution):
        return opened
    return await asyncio.shield(opened.future)


async def _open(authority, home: Path, need: AuthNeed, bot: str, key: tuple) -> _Request | Resolution:
    routes = _routes(authority)
    if not routes:
        return Resolution.NO_APP
    flow = auth_flows.flow_for(home, need.service)
    req = _Request(request_id=_new_id(), key=key, home=Path(home), authority=authority, service=need.service,
                   reason=need.reason, flow=flow, bots=[bot])
    _active[key] = req
    _by_id[req.request_id] = req
    try:
        try:
            await flow.begin()
        except Exception as exc:
            logger.warning("sign-in flow for %s could not start (%s); falling back to manual", need.service,
                           type(exc).__name__, exc_info=True)
            req.flow = auth_flows.ManualFlow()
        req.transports = await _broadcast(routes, _required_frame(req))
        if not req.transports:
            _finish(req, Resolution.NO_APP)
            return Resolution.NO_APP
        req.driver = asyncio.create_task(_drive(req))
    except BaseException:
        _finish(req, Resolution.UNAVAILABLE)
        raise
    return req


async def begin_signin(authority, home: Path, need: AuthNeed, bot: str) -> _Request | Resolution:
    key = _key(home, need.service)
    _declined_until.pop(key, None)
    existing = _active.get(key)
    if existing is not None:
        existing.transports = await _broadcast(_routes(authority), _required_frame(existing)) or existing.transports
        return existing
    return await _open(authority, home, need, bot, key)


def _new_id() -> str:
    import uuid
    return uuid.uuid4().hex


def _owned(authority, request_id: str) -> _Request | None:
    req = _by_id.get(request_id)
    return req if req is not None and req.authority is authority else None


async def signin(authority, request_id: str) -> tuple[bool, str | None]:
    req = _owned(authority, request_id)
    if req is None or req.future.done():
        return False, None
    req.signin_acknowledged = True
    confirm = getattr(req.flow, "confirm", None)
    if confirm is not None and not await confirm():
        return False, None
    if req.flow.kind == "oauth" and req.authorize_url is None and getattr(req.flow, "signin_on", None) is None:
        try:
            req.authorize_url = await req.flow.authorize_url()
        except Exception:
            logger.warning("sign-in for %s could not start", req.service, exc_info=True)
            await _conclude(req, Resolution.FAILED)
            return False, None
        if req.authorize_url is None and not getattr(req.flow, "already_connected", False):
            await _conclude(req, Resolution.FAILED)
            return False, None
    return True, req.authorize_url


async def complete(authority, home: Path, service: str) -> bool:
    """The service was signed in outside the prompt (the owner's computer handed over its tokens): end the
    waiting request, if any, as signed in."""
    req = _active.get(_key(home, service))
    if req is None or req.authority is not authority or req.future.done():
        return False
    await _conclude(req, Resolution.SIGNED_IN)
    return True


async def submit_credential(authority, request_id: str, value: str) -> CredentialOutcome:
    req = _owned(authority, request_id)
    store = getattr(req.flow, "store", None) if req is not None else None
    if req is None or store is None or req.future.done() or req.answering:
        return CredentialOutcome.REJECTED
    req.answering = True
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    scope = set_hermes_home_override(req.home)
    try:
        stored = await store(value)
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        from agent.redact import redact_sensitive_text
        detail = redact_sensitive_text(str(exc).replace(value, "<redacted>"), force=True)[:200]
        logger.warning("credential for %s was not saved (%s: %s)", req.service, type(exc).__name__, detail)
        stored = False
    finally:
        reset_hermes_home_override(scope)
    if not stored:
        req.answering = False
        return CredentialOutcome.FAILED
    await _conclude(req, Resolution.SIGNED_IN)
    return CredentialOutcome.STORED


async def decline(authority, request_id: str) -> bool:
    req = _owned(authority, request_id)
    if req is None or req.future.done():
        return False
    await _conclude(req, Resolution.DECLINED)
    if req.driver is not None:
        req.driver.cancel()
    return True


def forget_transport(transport) -> int:
    dropped = 0
    for req in list(_by_id.values()):
        if any(t is transport for t in req.transports):
            req.transports = [t for t in req.transports if t is not transport]
            dropped += 1
            if not req.transports and not req.future.done():
                req.flow.cancel()
                _finish(req, Resolution.NO_APP)
    return dropped


def call_from_thread(home: Path, need: AuthNeed, bot: str) -> Resolution:
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        return Resolution.UNAVAILABLE
    authority, loop = bound
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        return Resolution.UNAVAILABLE
    future = asyncio.run_coroutine_threadsafe(request_signin(authority, home, need, bot), loop)
    try:
        return future.result(SIGNIN_TIMEOUT_SECONDS + THREAD_WAIT_MARGIN_SECONDS)
    except concurrent.futures.TimeoutError:
        future.cancel()
        return Resolution.TIMED_OUT
