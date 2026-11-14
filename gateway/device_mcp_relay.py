from __future__ import annotations

import asyncio
import logging
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gateway.device_actions import clean_text
from gateway.device_tools import live_slots, route_rank
from gateway.reach_presence import ClientKind
from tools import mcp_tool_device as device_mcp
from tui_gateway.contracts.canonical_device import (
    DeviceMcpClosePayload,
    DeviceMcpCloseReason,
    DeviceMcpFailCode,
    DeviceMcpFramePayload,
    DeviceMcpServer,
)
from tui_gateway.device_frames import mcp_close_frame, mcp_frame

logger = logging.getLogger(__name__)

SERVER_KINDS = {DeviceMcpServer.T3CODE: frozenset({ClientKind.MAC})}
MAX_FAIL_TEXT = 300
AUTH_REASON = "expired"

_FAILURES = {
    DeviceMcpFailCode.UNREACHABLE: device_mcp.DeviceUnreachableError,
    DeviceMcpFailCode.AUTH_REQUIRED: device_mcp.DeviceAuthRequiredError,
    DeviceMcpFailCode.CLOSED: device_mcp.DeviceRelayClosedError,
}
_FAIL_DEFAULTS = {
    DeviceMcpFailCode.UNREACHABLE: "The app on the Mac cannot reach this server. Is it running?",
    DeviceMcpFailCode.AUTH_REQUIRED: "The server needs the owner to sign in again on the Mac.",
    DeviceMcpFailCode.CLOSED: "The Mac closed this connection.",
}


@dataclass(slots=True, eq=False)
class Relay:
    relay_id: str
    server: DeviceMcpServer
    name: str
    home: Path
    device_id: str
    authority: Any
    transport: Any
    channel: Any


_lock = threading.Lock()
_relays: dict[str, Relay] = {}
_signins: set[asyncio.Task] = set()


def _home_key(home: Path | str) -> Path:
    return Path(home).resolve()


def _take(relay_id: str) -> Relay | None:
    with _lock:
        return _relays.pop(relay_id, None)


def _take_where(match) -> list[Relay]:
    with _lock:
        taken = [relay for relay in _relays.values() if match(relay)]
        for relay in taken:
            del _relays[relay.relay_id]
    return taken


def _owned(authority, transport, relay_id: str) -> Relay | None:
    with _lock:
        relay = _relays.get(relay_id)
    return relay if relay is not None and relay.authority is authority and relay.transport is transport else None


async def _write(transport, frame: dict) -> bool:
    try:
        return bool(await asyncio.to_thread(transport.write, frame))
    except Exception:
        logger.debug("device MCP frame write failed", exc_info=True)
        return False


async def open_relay(home: Path, name: str, device_id: str, server: str, channel) -> Relay:
    from gateway.session_cron import owner_for_home
    bound = owner_for_home(home)
    if bound is None:
        raise device_mcp.DeviceUnreachableError("The gateway cannot reach this Mac right now.")
    authority, owner_loop = bound
    opening = asyncio.run_coroutine_threadsafe(
        _open_on_owner(authority, home, name, device_id, DeviceMcpServer(server), channel), owner_loop)
    return await asyncio.wrap_future(opening)


async def _open_on_owner(authority, home: Path, name: str, device_id: str, server: DeviceMcpServer,
                         channel) -> Relay:
    routes = sorted(live_slots(authority, time.time(), SERVER_KINDS[server], device_id),
                    key=lambda route: route_rank(route[1], route[2]), reverse=True)
    if not routes:
        raise device_mcp.DeviceUnreachableError("That Mac is offline.")
    relay = Relay(uuid.uuid4().hex, server, name, _home_key(home), device_id, authority, routes[0][0], channel)
    with _lock:
        _relays[relay.relay_id] = relay
    return relay


async def send(relay: Relay, message: dict) -> None:
    frame = mcp_frame(DeviceMcpFramePayload(relay_id=relay.relay_id, server=relay.server, message=message))
    if not await _write(relay.transport, frame):
        _take(relay.relay_id)
        raise device_mcp.DeviceUnreachableError("The Mac stopped answering.")


async def close_relay(relay: Relay, reason: DeviceMcpCloseReason) -> None:
    if _take(relay.relay_id) is None:
        return
    await _write(relay.transport, mcp_close_frame(DeviceMcpClosePayload(relay_id=relay.relay_id, reason=reason)))


async def deliver(authority, transport, relay_id: str, message: dict) -> bool:
    relay = _owned(authority, transport, relay_id)
    if relay is None:
        return False
    size = await asyncio.to_thread(device_mcp.encoded_size, message)
    if size > device_mcp.MAX_MESSAGE_BYTES:
        _take(relay_id)
        relay.channel.post_failure(device_mcp.DeviceMessageTooLargeError(
            f"The Mac sent an MCP message of {size} bytes, over the {device_mcp.MAX_MESSAGE_BYTES} byte limit."))
        await _write(transport, mcp_close_frame(
            DeviceMcpClosePayload(relay_id=relay_id, reason=DeviceMcpCloseReason.CLIENT_CLOSED)))
        return False
    return relay.channel.post_message(message)


async def fail(authority, transport, relay_id: str, code: DeviceMcpFailCode, message: str) -> bool:
    relay = _owned(authority, transport, relay_id)
    if relay is None or _take(relay_id) is None:
        return False
    text = clean_text(message, MAX_FAIL_TEXT) or _FAIL_DEFAULTS[code]
    if code is DeviceMcpFailCode.AUTH_REQUIRED:
        device_mcp.mark_auth_required(relay.home, relay.name, AUTH_REASON)
        _offer_signin(relay)
    relay.channel.post_failure(_FAILURES[code](text))
    return True


def _offer_signin(relay: Relay) -> None:
    from gateway import auth_prompts
    from hermes_constants import profile_name_for_home, reset_hermes_home_override, set_hermes_home_override
    from tools.auth_required import AuthNeed
    need = AuthNeed(f"mcp:{relay.name}", AUTH_REASON, flow="oauth")
    bot = profile_name_for_home(relay.home) or "default"
    scope = set_hermes_home_override(relay.home)
    try:
        task = asyncio.get_running_loop().create_task(auth_prompts.request_signin(relay.authority, relay.home, need, bot))
    finally:
        reset_hermes_home_override(scope)
    _signins.add(task)
    task.add_done_callback(_signins.discard)


def forget_transport(transport) -> int:
    dropped = _take_where(lambda relay: relay.transport is transport)
    for relay in dropped:
        relay.channel.post_failure(device_mcp.DeviceDisconnectedError("The Mac disconnected."))
    return len(dropped)


async def close_relays(home: Path, name: str, reason: DeviceMcpCloseReason) -> int:
    key = _home_key(home)
    dropped = _take_where(lambda relay: relay.home == key and relay.name == name)
    for relay in dropped:
        relay.channel.post_failure(device_mcp.DeviceRelayClosedError("The Mac no longer offers this server."))
        await _write(relay.transport, mcp_close_frame(DeviceMcpClosePayload(relay_id=relay.relay_id, reason=reason)))
    return len(dropped)
