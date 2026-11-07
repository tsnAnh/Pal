from __future__ import annotations

import asyncio
import logging
import sqlite3
import time
from functools import partial
from pathlib import Path

from pydantic import ValidationError

from gateway import device_registry
from gateway.reach_presence import AttentionState, ClientKind, Device, declare, report_attention, slot_of
from hermes_state_runtime import RuntimeStoreError

logger = logging.getLogger(__name__)


def _authority_home(authority) -> Path:
    return Path(authority.db.db_path).resolve().parent


def _same_host(connection) -> bool:
    return bool(connection.native_owner or getattr(connection.transport, 'desktop_local', False))


def _require_actor(connection) -> None:
    if not connection.actor.capabilities:
        raise RuntimeStoreError('permission_denied')


def _clean(text: str) -> str:
    return ' '.join(text.split())


async def _persist(connection, call, *args, **kwargs) -> None:
    root = device_registry.install_root(connection.authority.profile_id)
    try:
        await asyncio.to_thread(call, root, *args, **kwargs)
    except (sqlite3.Error, OSError) as exc:
        logger.warning('Could not record device presence: %s', type(exc).__name__)


async def hello(connection, ref, params):
    from tui_gateway.contracts.canonical_reach import ClientHelloParams
    _require_actor(connection)
    try:
        parsed = ClientHelloParams.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc
    label = _clean(parsed.label)
    if not label or not label.isprintable():
        raise RuntimeStoreError('invalid_params')
    model, os_name = _clean(parsed.model), _clean(parsed.os)
    if not model.isprintable() or not os_name.isprintable():
        raise RuntimeStoreError('invalid_params')
    device = Device(kind=ClientKind(parsed.kind), device_id=parsed.device_id, label=label,
                    app_version=parsed.app_version.strip(), model=model, os_name=os_name)
    slot = declare(connection.transport, device, accepts_offers=parsed.accepts_offers,
                   same_host=_same_host(connection), attention=AttentionState(parsed.attention),
                   device_tools=parsed.device_tools and device.kind is ClientKind.IOS)
    await _persist(connection, device_registry.record_hello, device_id=device.device_id, kind=device.kind.value,
                   label=device.label, model=device.model, os_name=device.os_name,
                   app_version=device.app_version, now=time.time())
    if slot.device_tools:
        from gateway import device_connectors
        try:
            await asyncio.to_thread(device_connectors.register_device, _authority_home(connection.authority),
                                    device.device_id, device.label)
        except device_connectors.StoreUnreadable as exc:
            raise RuntimeStoreError('storage_unavailable', detail=str(exc)) from exc
    return {'recorded': True, 'same_host': slot.same_host}


async def attention(connection, ref, params):
    from tui_gateway.contracts.canonical_reach import ClientAttentionParams
    _require_actor(connection)
    try:
        parsed = ClientAttentionParams.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc
    slot = report_attention(connection.transport, AttentionState(parsed.state))
    if slot is not None:
        await _persist(connection, device_registry.touch, slot.device.device_id, time.time())
    return {'recorded': slot is not None}


async def departed(connection) -> None:
    slot = slot_of(connection.transport)
    if slot is not None:
        await _persist(connection, device_registry.touch, slot.device.device_id, time.time())


def handlers(connection):
    return {'client.hello': partial(hello, connection), 'client.attention': partial(attention, connection)}
