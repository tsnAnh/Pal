from __future__ import annotations

import asyncio
import logging
import time
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from gateway import reach_log, reach_routes
from gateway.reach_policy import (
    AppSocket, Consent, LogView, OfferKind, Policy, Route, Verdict, judge, load_policy,
)
from gateway.reach_presence import Device

logger = logging.getLogger(__name__)

ACK_TIMEOUT_SECONDS = 15.0
OFFER_WAIT_TIMEOUT_SECONDS = 180.0
MESSAGING_TEXT_LIMIT = 3500
REMEMBERED_OFFERS = 256

__all__ = [
    "ACK_TIMEOUT_SECONDS", "Consent", "Delivery", "Disposition", "DurableLane", "Offer", "OfferKind",
    "Outcome", "drain_deferred", "drain_deferred_threadsafe", "offer", "offer_threadsafe", "record_outcome",
]


class Disposition(StrEnum):
    ALERTED = "alerted"
    LANDED_SILENT = "landed_silent"
    DEFERRED = "deferred"
    SUPPRESSED = "suppressed"
    UNKNOWN = "unknown"


class Outcome(StrEnum):
    SHOWN = "shown"
    ACTED = "acted"
    DISMISSED = "dismissed"


@dataclass(frozen=True, slots=True)
class DurableLane:
    session_id: str | None = None
    land: Callable[[], str | None] | None = None


@dataclass(frozen=True, slots=True)
class Offer:
    producer_key: str
    domain: str
    kind: OfferKind
    consent: Consent
    title: str
    body: str
    lane: DurableLane | None = None
    lane_text: str | None = None


@dataclass(frozen=True, slots=True)
class Delivery:
    offer_id: str
    disposition: Disposition
    route: Route | None
    tried: tuple[Route, ...]
    reason: str
    error: str | None = None


@dataclass(slots=True)
class _Pending:
    future: asyncio.Future
    transport: object


_pending: dict[str, _Pending] = {}
_remembered: OrderedDict[str, Offer] = OrderedDict()
_sent: OrderedDict[str, tuple[Path, object]] = OrderedDict()

_DISPOSITIONS = {
    "alerted": Disposition.ALERTED, "landed_silent": Disposition.LANDED_SILENT,
    "deferred": Disposition.DEFERRED, "suppressed": Disposition.SUPPRESSED,
}


def _resolved(home) -> Path:
    return Path(home).resolve()


def _record_sent(offer_id: str, home: Path, transport) -> None:
    _sent[offer_id] = (home, transport)
    _sent.move_to_end(offer_id)
    while len(_sent) > REMEMBERED_OFFERS:
        _sent.popitem(last=False)


def _home_for_outcome(home: Path, offer_id: str, transport) -> Path:
    sent = _sent.get(offer_id)
    return sent[0] if sent is not None and transport is not None and sent[1] is transport else home


def _remember(offer_id: str, item: Offer) -> None:
    _remembered[offer_id] = item
    while len(_remembered) > REMEMBERED_OFFERS:
        _remembered.popitem(last=False)


def _existing_delivery(row: dict) -> Delivery:
    disposition = _DISPOSITIONS.get(row["status"], Disposition.UNKNOWN)
    reason = "in_progress" if row["status"] == "routing" else row["reason"]
    return Delivery(row["offer_id"], disposition, None, (), reason)


def _judged_offer(row: dict) -> Offer:
    return Offer(producer_key=row["producer_key"], domain=row["domain"], kind=OfferKind(row["kind"]),
                 consent=Consent(row["consent"]), title=row["title"], body="")


def _load_policy_and_clock(authority, home: Path):
    import hermes_time
    from hermes_cli.config_effective import load_user_config_effective
    from gateway.session_authorities import owner_scope
    with owner_scope(authority):
        policy = load_policy(load_user_config_effective(home / "config.yaml"))
        return policy, hermes_time.now()


def _claim(authority, home: Path, item: Offer):
    policy, now_local = _load_policy_and_clock(authority, home)

    def decide(view: LogView) -> Verdict:
        return judge(item, policy, view, now_local)

    claim = reach_log.claim(
        home, producer_key=item.producer_key, domain=item.domain, kind=item.kind.value,
        consent=item.consent.value, title=item.title, judge=decide, now=now_local.timestamp())
    return claim, policy


def _reclaim(authority, home: Path, row: dict):
    policy, now_local = _load_policy_and_clock(authority, home)
    stand_in = _judged_offer(row)
    claim = reach_log.claim_deferred(
        home, row["offer_id"], judge=lambda view: judge(stand_in, policy, view, now_local),
        now=now_local.timestamp())
    return claim, policy


def _land(authority, home: Path, item: Offer) -> str | None:
    lane = item.lane
    if lane is None:
        return None
    from gateway.session_authorities import owner_scope
    with owner_scope(authority):
        if lane.land is not None:
            return lane.land()
        if lane.session_id:
            from gateway.session_cron import deliver_to_local_chat
            return deliver_to_local_chat(home, lane.session_id, item.lane_text or item.body)
    return None


def _ranked_routes(authority, home: Path, policy: Policy):
    return reach_routes.routes(authority, home, policy)


def _messaging_text(item: Offer) -> str:
    text = f"{item.title}\n\n{item.body}" if item.body else item.title
    return text[:MESSAGING_TEXT_LIMIT]


def _route_summary(route: Route) -> dict:
    if isinstance(route.channel, AppSocket):
        return {"kind": "app", "device_id": route.device_id, "label": route.label,
                "attention": route.attention.name.lower()}
    return {"kind": "messaging", "platform": route.channel.platform, "origin": route.channel.origin}


async def _alert_app(authority, home: Path, route: Route, offer_id: str, item: Offer, ack_timeout: float) -> str:
    from tui_gateway.reach_frames import offer_frame
    transport = authority.events.get(route.channel.transport_id)
    if transport is None:
        return "gone"
    frame = offer_frame(offer_id=offer_id, kind=item.kind.value, domain=item.domain, title=item.title,
                        body=item.body, session_id=item.lane.session_id if item.lane else None)
    future = asyncio.get_running_loop().create_future()
    _pending[offer_id] = _Pending(future, transport)
    _record_sent(offer_id, home, transport)
    try:
        if not await asyncio.to_thread(transport.write, frame):
            return "send_failed"
        try:
            await asyncio.wait_for(future, ack_timeout)
        except TimeoutError:
            return "no_ack"
        return "ack"
    finally:
        _pending.pop(offer_id, None)


async def _alert_messaging(authority, route: Route, item: Offer) -> str:
    try:
        sent = await reach_routes.send_messaging(authority, route.channel, _messaging_text(item))
    except Exception:
        logger.warning("Proactive messaging alert failed", exc_info=True)
        return "send_failed"
    return "ack" if sent else "send_failed"


async def _try_route(authority, home: Path, route: Route, offer_id: str, item: Offer, ack_timeout: float) -> str:
    if isinstance(route.channel, AppSocket):
        return await _alert_app(authority, home, route, offer_id, item, ack_timeout)
    return await _alert_messaging(authority, route, item)


async def _walk_routes(authority, home: Path, policy: Policy, offer_id: str, item: Offer, ack_timeout: float):
    candidates = await asyncio.to_thread(_ranked_routes, authority, home, policy)
    tried = []
    for route in candidates:
        result = await _try_route(authority, home, route, offer_id, item, ack_timeout)
        tried.append(route)
        await asyncio.to_thread(reach_log.append_attempt, home, offer_id, {
            "at": time.time(), "result": result, **_route_summary(route)})
        if result == "ack":
            return route, tuple(tried), ""
    return None, tuple(tried), "unacknowledged" if tried else "no_route"


async def _alert_and_finalize(authority, home: Path, policy: Policy, offer_id: str, item: Offer,
                              ack_timeout: float, error: str | None) -> Delivery:
    try:
        route, tried, reason = await _walk_routes(authority, home, policy, offer_id, item, ack_timeout)
    except BaseException:
        await asyncio.shield(asyncio.to_thread(
            reach_log.finalize, home, offer_id, status="unknown", reason="interrupted"))
        raise
    if route is None:
        await asyncio.to_thread(reach_log.finalize, home, offer_id, status="landed_silent", reason=reason)
        return Delivery(offer_id, Disposition.LANDED_SILENT, None, tried, reason, error)
    await asyncio.to_thread(reach_log.finalize, home, offer_id, status="alerted", reason="",
                            route=_route_summary(route), alerted_at=time.time())
    return Delivery(offer_id, Disposition.ALERTED, route, tried, "", error)


async def offer(home, item: Offer, *, ack_timeout: float = ACK_TIMEOUT_SECONDS) -> Delivery:
    home = _resolved(home)
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        return Delivery("", Disposition.UNKNOWN, None, (), "no_owner")
    authority = bound[0]
    claim, policy = await asyncio.to_thread(_claim, authority, home, item)
    row = claim.row
    if not claim.created:
        return _existing_delivery(row)
    verdict = claim.verdict
    error = await asyncio.to_thread(_land, authority, home, item) if verdict.land else None
    if verdict.alert:
        return await _alert_and_finalize(authority, home, policy, row["offer_id"], item, ack_timeout, error)
    if row["status"] == "deferred":
        _remember(row["offer_id"], item)
    return Delivery(row["offer_id"], _DISPOSITIONS[row["status"]], None, (), verdict.reason, error)


def _settle(future: asyncio.Future) -> None:
    def resolve() -> None:
        if not future.done():
            future.set_result(True)
    future.get_loop().call_soon_threadsafe(resolve)


async def record_outcome(home, offer_id: str, outcome: Outcome, device: Device | None, transport=None) -> bool:
    home = _home_for_outcome(_resolved(home), offer_id, transport)
    row, _applied = await asyncio.to_thread(
        reach_log.record_outcome, home, offer_id, outcome.value, device.device_id if device else None, time.time())
    if row is None:
        return False
    pending = _pending.get(offer_id)
    if pending is not None and (transport is None or pending.transport is transport):
        _settle(pending.future)
    return True


async def drain_deferred(home, *, ack_timeout: float = ACK_TIMEOUT_SECONDS) -> int:
    home = _resolved(home)
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        return 0
    authority = bound[0]
    now = time.time()
    await asyncio.to_thread(reach_log.maintain_throttled, home, now)
    due = await asyncio.to_thread(reach_log.due_deferred, home, now)
    resumed = 0
    for row in due:
        claim, policy = await asyncio.to_thread(_reclaim, authority, home, row)
        if claim is None:
            continue
        resumed += 1
        if claim.verdict.alert:
            item = _remembered.pop(row["offer_id"], None) or _judged_offer(row)
            await _alert_and_finalize(authority, home, policy, row["offer_id"], item, ack_timeout, None)
    return resumed


def _log_failure(task_or_future) -> None:
    if task_or_future.cancelled():
        return
    error = task_or_future.exception()
    if error is not None:
        logger.warning("Proactive delivery failed: %r", error, exc_info=error)


def _schedule(home, coro_factory: Callable[[], object], *, wait: bool, timeout: float):
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        return None
    loop = bound[1]
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        loop.create_task(coro_factory()).add_done_callback(_log_failure)
        return None
    future = asyncio.run_coroutine_threadsafe(coro_factory(), loop)
    if not wait:
        future.add_done_callback(_log_failure)
        return None
    return future.result(timeout)


def offer_threadsafe(home, item: Offer, *, wait: bool = True,
                     timeout: float = OFFER_WAIT_TIMEOUT_SECONDS) -> Delivery | None:
    return _schedule(home, lambda: offer(home, item), wait=wait, timeout=timeout)


def drain_deferred_threadsafe(home) -> None:
    _schedule(home, lambda: drain_deferred(home), wait=False, timeout=0.0)
