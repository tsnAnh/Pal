from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from gateway import device_mcp_relay
from hermes_state_runtime import RuntimeStoreError
from tools import mcp_tool_device as device_mcp
from tui_gateway.contracts.canonical_device import DeviceMcpCloseReason, DeviceMcpServer

logger = logging.getLogger(__name__)

CREATED = "created"
UNCHANGED = "unchanged"
REBOUND = "rebound"

_background: set[asyncio.Task] = set()


def server_config(server: DeviceMcpServer, device_id: str) -> dict:
    return {"transport": device_mcp.DEVICE_TRANSPORT, "device_id": device_id, "server": server.value}


def _persist(home: Path, name: str, config: dict) -> str:
    from gateway.run import _profile_runtime_scope
    from hermes_cli import mcp_config
    with _profile_runtime_scope(home):
        existing = mcp_config._get_mcp_servers().get(name)
        if existing is not None and not device_mcp.is_device_config(existing):
            raise RuntimeStoreError("invalid_params", field="server", detail="another server already uses this name")
        merged = {**(existing or {}), **config}
        if merged == existing:
            return UNCHANGED
        if not mcp_config._save_mcp_server(name, merged):
            raise RuntimeStoreError("permission_denied", field="server", detail="this bot cannot change its servers")
        return CREATED if existing is None else REBOUND


def _remove(home: Path, name: str, device_id: str) -> bool:
    from gateway.run import _profile_runtime_scope
    from hermes_cli import mcp_config
    with _profile_runtime_scope(home):
        existing = mcp_config._get_mcp_servers().get(name)
        if not device_mcp.is_device_config(existing):
            return False
        if existing.get("device_id") != device_id:
            raise RuntimeStoreError("permission_denied", field="server", detail="another Mac registered this server")
        return mcp_config._remove_mcp_server(name)


def _reconcile(home: Path, name: str) -> dict:
    from gateway.run import _profile_runtime_scope
    from tools import mcp_tool_discovery
    from tools.mcp_oauth import suppress_interactive_oauth
    with _profile_runtime_scope(home), suppress_interactive_oauth():
        result = mcp_tool_discovery.reconcile_mcp_servers_with_config()
        device_mcp.revive_server(name)
        return result


async def _bring_up(home: Path, name: str) -> None:
    try:
        await asyncio.to_thread(_reconcile, home, name)
    except Exception:
        logger.warning("Could not bring the %s device server in step with its registration", name, exc_info=True)


def _spawn(coroutine) -> None:
    task = asyncio.get_running_loop().create_task(coroutine)
    _background.add(task)
    task.add_done_callback(_background.discard)


async def settled() -> None:
    while _background:
        await asyncio.gather(*list(_background), return_exceptions=True)


async def register(authority, home: Path, device_id: str, server: DeviceMcpServer) -> None:
    name = server.value
    outcome = await asyncio.to_thread(_persist, home, name, server_config(server, device_id))
    if outcome == REBOUND:
        await device_mcp_relay.close_relays(home, name, DeviceMcpCloseReason.UNREGISTERED)
    if device_mcp.clear_auth_required(home, name):
        from gateway import auth_prompts
        await auth_prompts.complete(authority, home, f"mcp:{name}")
    _spawn(_bring_up(home, name))


async def unregister(home: Path, device_id: str, server: DeviceMcpServer) -> None:
    name = server.value
    await asyncio.to_thread(_remove, home, name, device_id)
    await device_mcp_relay.close_relays(home, name, DeviceMcpCloseReason.UNREGISTERED)
    device_mcp.forget_auth(home, name)
    _spawn(_bring_up(home, name))
