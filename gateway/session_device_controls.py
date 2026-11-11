from __future__ import annotations

import asyncio
from functools import partial
from pathlib import Path

from pydantic import ValidationError

from gateway import device_connectors, device_tools
from gateway.reach_presence import slot_of
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts.canonical_device import (
    DeviceConnectorId,
    DeviceConnectorsListParams,
    DeviceConnectorsSetParams,
    DeviceToolRespondParams,
)


SELF_SWITCHED = frozenset({DeviceConnectorId.SHELL, DeviceConnectorId.FILES})


def _authority_home(authority) -> Path:
    return Path(authority.db.db_path).resolve().parent


def _require(connection, capability) -> None:
    if capability not in connection.actor.capabilities:
        raise RuntimeStoreError('permission_denied')


def _parse(model, params):
    try:
        return model.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc


def _own_device_id(connection) -> str | None:
    slot = slot_of(connection.transport)
    return slot.device.device_id if slot is not None and slot.device_tools else None


def _result(device_id: str, statuses) -> dict:
    return {'device_id': device_id, 'connectors': [
        {'id': s.connector.value, 'title': s.title, 'subtitle': s.subtitle, 'state': s.state.value,
         'os_permission': s.os_permission.value} for s in statuses]}


def _unreadable(exc: device_connectors.StoreUnreadable) -> RuntimeStoreError:
    return RuntimeStoreError('storage_unavailable', detail=str(exc))


async def list_connectors(connection, ref, params):
    _require(connection, 'session:read')
    parsed = _parse(DeviceConnectorsListParams, params)
    device_id = parsed.device_id or _own_device_id(connection)
    if device_id is None:
        raise RuntimeStoreError('invalid_params', field='device_id', detail='declare the device with client.hello first')
    try:
        statuses = await asyncio.to_thread(device_connectors.statuses, _authority_home(connection.authority), device_id)
    except device_connectors.UnknownDevice as exc:
        raise RuntimeStoreError('not_found', field='device_id') from exc
    except device_connectors.StoreUnreadable as exc:
        raise _unreadable(exc) from exc
    return _result(device_id, statuses)


async def set_connector(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceConnectorsSetParams, params)
    if parsed.state is None and parsed.os_permission is None:
        raise RuntimeStoreError('invalid_params', detail='state or os_permission is required')
    own = _own_device_id(connection)
    device_id = parsed.device_id or own
    if device_id is None:
        raise RuntimeStoreError('invalid_params', field='device_id', detail='declare the device with client.hello first')
    if parsed.id in SELF_SWITCHED and parsed.state is not None and device_id != own:
        raise RuntimeStoreError('permission_denied', field='device_id',
                                detail='only the device itself switches on commands and files')
    if parsed.os_permission is not None and device_id != own:
        raise RuntimeStoreError('permission_denied', field='os_permission',
                                detail='only the device itself reports its OS permission')
    try:
        statuses = await asyncio.to_thread(
            partial(device_connectors.update, _authority_home(connection.authority), device_id, parsed.id,
                    state=parsed.state, os_permission=parsed.os_permission))
    except device_connectors.UnknownDevice as exc:
        raise RuntimeStoreError('not_found', field='device_id') from exc
    except device_connectors.StoreUnreadable as exc:
        raise _unreadable(exc) from exc
    return _result(device_id, statuses)


async def respond(connection, ref, params):
    _require(connection, 'session:control')
    parsed = _parse(DeviceToolRespondParams, params)
    if parsed.ok == (parsed.error is not None) or (parsed.ok and parsed.result is None):
        raise RuntimeStoreError('invalid_params', detail='ok carries result, not ok carries error')
    recorded = await device_tools.respond(
        connection.authority, connection.transport, parsed.request_id, ok=parsed.ok, result=parsed.result,
        error_code=parsed.error.code if parsed.error else None,
        error_message=parsed.error.message if parsed.error else '')
    return {'recorded': recorded}


def handlers(connection):
    return {'device_connectors.list': partial(list_connectors, connection),
            'device_connectors.set': partial(set_connector, connection),
            'device.tool.respond': partial(respond, connection)}
