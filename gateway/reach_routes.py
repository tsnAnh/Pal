from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, replace
from pathlib import Path

from gateway import reach_log
from gateway.reach_policy import AppSocket, Messaging, Policy, Route, rank
from gateway.reach_presence import Attention, attention_of, last_frame_at, slot_of

logger = logging.getLogger(__name__)

NON_MESSAGING_SOURCES = frozenset({
    "local", "cli", "tui", "gui", "desktop", "ios", "acp", "tool", "oneshot", "cron",
    "api_server", "webhook", "bot-chat", "bot_chat", "reach"})


@dataclass(frozen=True, slots=True)
class _Home:
    chat_id: str
    thread_id: str | None
    user_id: str | None
    scope_id: str | None


def _device_input_times(authority) -> dict[str, float]:
    latest: dict[str, float] = {}
    for transport in list(authority.events.values()):
        slot = slot_of(transport)
        if slot is not None and slot.last_input_at is not None:
            device_id = slot.device.device_id
            latest[device_id] = max(latest.get(device_id, 0.0), slot.last_input_at)
    return latest


def app_routes(authority, now: float) -> list[Route]:
    routes = []
    device_input = _device_input_times(authority)
    for transport_id, transport in list(authority.events.items()):
        slot = slot_of(transport)
        if slot is None or not slot.accepts_offers:
            continue
        last_input_at = device_input.get(slot.device.device_id, slot.last_input_at)
        attention = attention_of(replace(slot, last_input_at=last_input_at), last_frame=last_frame_at(transport), now=now)
        routes.append(Route(
            channel=AppSocket(transport_id), attention=attention, last_input_at=last_input_at,
            attention_at=slot.attention_at, device_id=slot.device.device_id, label=slot.device.label))
    return routes


def served_messaging(authority):
    runner = authority.runner
    registry = getattr(runner, "session_authorities", None)
    name = registry.profile_name(authority) if registry is not None else None
    if name is None:
        return getattr(runner, "config", None), getattr(runner, "adapters", None) or {}
    config = (getattr(runner, "_profile_configs", None) or {}).get(name)
    return config, runner._adapters_for_profile(name)


def transport_for(authority, platform_name: str):
    from gateway.config import Platform
    from gateway.delivery import resolve_delivery_transport
    config, adapters = served_messaging(authority)
    if config is None:
        return None
    try:
        platform = Platform(platform_name.lower())
        transport = resolve_delivery_transport(platform, config, adapters)
    except (ValueError, KeyError, AttributeError, TypeError):
        logger.debug("No live transport for %s", platform_name, exc_info=True)
        return None
    return None if transport is None else (platform, transport)


def _home_order(platform_name: str) -> tuple[int, str]:
    from cron.scheduler_delivery import _HOME_TARGET_PRIORITY
    try:
        return _HOME_TARGET_PRIORITY.index(platform_name), platform_name
    except ValueError:
        return len(_HOME_TARGET_PRIORITY), platform_name


def home_channel_routes(authority) -> list[Route]:
    config, _adapters = served_messaging(authority)
    if config is None:
        return []
    found = []
    for platform, platform_config in config.platforms.items():
        home = platform_config.home_channel
        if not home or not home.chat_id or transport_for(authority, platform.value) is None:
            continue
        found.append(Messaging(
            platform=platform.value, chat_id=str(home.chat_id), thread_id=str(home.thread_id) if home.thread_id else None,
            user_id=getattr(home, "user_id", None), scope_id=getattr(home, "scope_id", None), origin="home"))
    found.sort(key=lambda m: _home_order(m.platform))
    return [Route(channel=m, attention=Attention.REACHABLE, last_input_at=None, attention_at=None) for m in found]


def _origin_ids(origin_json) -> tuple[str | None, str | None]:
    try:
        origin = json.loads(origin_json) if origin_json else {}
    except (TypeError, ValueError):
        return None, None
    if not isinstance(origin, dict):
        return None, None
    user_id, scope_id = origin.get("user_id"), origin.get("scope_id")
    return (str(user_id) if user_id else None, str(scope_id) if scope_id else None)


def recent_chat_route(authority, home: Path, policy: Policy, now: float) -> Route | None:
    since = now - policy.messaging_window.total_seconds()
    recent = reach_log.latest_inbound_chat(home, since, NON_MESSAGING_SOURCES)
    if recent is None or transport_for(authority, recent["platform"]) is None:
        return None
    user_id, scope_id = _origin_ids(recent["origin_json"])
    channel = Messaging(platform=recent["platform"], chat_id=str(recent["chat_id"]), thread_id=recent["thread_id"],
                        user_id=user_id, scope_id=scope_id, origin="recent")
    return Route(channel=channel, attention=Attention.REACHABLE, last_input_at=recent["at"], attention_at=recent["at"])


def candidate_routes(authority, home: Path, policy: Policy, now: float) -> list[Route]:
    routes = app_routes(authority, now)
    recent = recent_chat_route(authority, home, policy, now)
    if recent is not None:
        routes.append(recent)
    seen = {_channel_key(recent.channel)} if recent is not None else set()
    for route in home_channel_routes(authority):
        key = _channel_key(route.channel)
        if key not in seen:
            seen.add(key)
            routes.append(route)
    return routes


def _channel_key(channel: Messaging) -> tuple:
    return (channel.platform, channel.chat_id, channel.thread_id)


def routes(authority, home: Path, policy: Policy, now: float | None = None) -> tuple[Route, ...]:
    return rank(candidate_routes(authority, home, policy, time.time() if now is None else now))


async def send_messaging(authority, channel: Messaging, text: str) -> bool:
    resolved = transport_for(authority, channel.platform)
    if resolved is None:
        return False
    platform, transport = resolved
    target = _Home(channel.chat_id, channel.thread_id, channel.user_id, channel.scope_id)
    return await authority.runner._send_home_channel_message(
        platform, target, transport, text, "Proactive alert to %s:%s not delivered: %s")
