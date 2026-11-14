from __future__ import annotations

from functools import partial

from gateway import device_mcp_registration, device_mcp_relay
from gateway.reach_presence import slot_of
from gateway.session_device_controls import _authority_home, _parse, _require
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts.canonical_device import (
    DeviceMcpDeliverParams,
    DeviceMcpFailParams,
    DeviceMcpRegisterParams,
    DeviceMcpServer,
)


def _own_device_id(connection, server: DeviceMcpServer) -> str:
    slot = slot_of(connection.transport)
    if slot is None or not slot.device_tools:
        raise RuntimeStoreError('invalid_params', field='server',
                                detail='declare the device and its tools with client.hello first')
    if slot.device.kind not in device_mcp_relay.SERVER_KINDS[server]:
        raise RuntimeStoreError('permission_denied', field='server', detail='this device cannot offer this server')
    return slot.device.device_id


def _registration(server: DeviceMcpServer, registered: bool) -> dict:
    return {'registered': registered, 'name': server.value}


async def register(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceMcpRegisterParams, params)
    device_id = _own_device_id(connection, parsed.server)
    await device_mcp_registration.register(
        connection.authority, _authority_home(connection.authority), device_id, parsed.server)
    return _registration(parsed.server, True)


async def unregister(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceMcpRegisterParams, params)
    device_id = _own_device_id(connection, parsed.server)
    await device_mcp_registration.unregister(_authority_home(connection.authority), device_id, parsed.server)
    return _registration(parsed.server, False)


async def deliver(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceMcpDeliverParams, params)
    accepted = await device_mcp_relay.deliver(connection.authority, connection.transport, parsed.relay_id,
                                              parsed.message)
    return {'accepted': accepted}


async def fail(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceMcpFailParams, params)
    recorded = await device_mcp_relay.fail(connection.authority, connection.transport, parsed.relay_id,
                                           parsed.code, parsed.message)
    return {'recorded': recorded}


def handlers(connection):
    return {'device.mcp.register': partial(register, connection),
            'device.mcp.unregister': partial(unregister, connection),
            'device.mcp.deliver': partial(deliver, connection),
            'device.mcp.fail': partial(fail, connection)}
