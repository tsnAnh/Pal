from __future__ import annotations

import asyncio
import logging
import sqlite3
import time
from datetime import UTC, datetime
from functools import partial
from pathlib import Path

from pydantic import ValidationError

from gateway import device_registry
from gateway.device_presence import live_attention, served_authorities, transports_of
from gateway.push_apns import load_config
from gateway.reach_presence import Attention, slot_of
from hermes_state_runtime import RuntimeStoreError

logger = logging.getLogger(__name__)


def _root(connection) -> Path:
    return device_registry.install_root(connection.authority.profile_id)


def _require(connection, capability: str) -> None:
    if capability not in connection.actor.capabilities:
        raise RuntimeStoreError("permission_denied")


def _parse(model, params):
    try:
        return model.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError("invalid_params") from exc


def _declared_device_id(connection) -> str | None:
    slot = slot_of(connection.transport)
    return slot.device.device_id if slot is not None else None


def _iso(stamp: float) -> str:
    return datetime.fromtimestamp(stamp, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _storage(call, *args, **kwargs):
    try:
        return call(*args, **kwargs)
    except (sqlite3.Error, OSError) as exc:
        logger.warning("Device registry unavailable: %s", type(exc).__name__)
        raise RuntimeStoreError("storage_unavailable") from exc


async def devices_list(connection, ref, params):
    from tui_gateway.contracts.canonical_devices import DevicesListParams
    _require(connection, "session:read")
    _parse(DevicesListParams, params)
    root, now = _root(connection), time.time()
    levels = live_attention(served_authorities(connection.authority), now)
    own = _declared_device_id(connection)

    def read():
        return device_registry.list_devices(root), load_config(root) is not None

    records, push_configured = await asyncio.to_thread(_storage, read)
    devices = []
    for record in records:
        online = levels.get(record.device_id, Attention.PARKED) > Attention.PARKED
        row = {"device_id": record.device_id, "kind": record.kind, "label": record.label,
               "this_device": record.device_id == own, "online": online,
               "last_seen_at": _iso(now if online else record.last_seen_at),
               "push_enabled": record.has_push_token and push_configured}
        if record.model:
            row["model"] = record.model
        if record.os:
            row["os"] = record.os
        devices.append(row)
    return {"devices": devices}


async def devices_forget(connection, ref, params):
    from tui_gateway.contracts.canonical_devices import DevicesForgetParams
    _require(connection, "session:control")
    parsed = _parse(DevicesForgetParams, params)
    own = _declared_device_id(connection)
    if parsed.device_id == own and not parsed.confirm_self:
        raise RuntimeStoreError("confirm_required", field="device_id",
                                detail="this is the calling device; resend with confirm_self")
    outcome = await asyncio.to_thread(_storage, device_registry.forget, _root(connection), parsed.device_id,
                                      time.time())
    for transport in transports_of(served_authorities(connection.authority), parsed.device_id):
        if transport is not connection.transport:
            (getattr(transport, "abort", None) or transport.close)()
    return {"forgotten": outcome.existed or outcome.grants_revoked > 0, "grants_revoked": outcome.grants_revoked,
            "push_removed": outcome.push_removed}


def _own_device(connection, device_id: str) -> None:
    declared = _declared_device_id(connection)
    if declared is None:
        raise RuntimeStoreError("hello_required", detail="declare this device with client.hello first")
    if declared != device_id:
        raise RuntimeStoreError("device_mismatch", field="device_id")


async def push_register(connection, ref, params):
    from tui_gateway.contracts.canonical_devices import PushRegisterParams
    _require(connection, "session:control")
    parsed = _parse(PushRegisterParams, params)
    _own_device(connection, parsed.device_id)
    root = _root(connection)

    def write():
        stored = device_registry.set_push_token(root, parsed.device_id, parsed.apns_token.lower(),
                                                parsed.environment, parsed.bundle_id, time.time())
        return stored, load_config(root) is not None

    stored, configured = await asyncio.to_thread(_storage, write)
    if not stored:
        raise RuntimeStoreError("hello_required", detail="declare this device with client.hello first")
    return {"registered": True, "push_enabled": configured}


async def push_unregister(connection, ref, params):
    from tui_gateway.contracts.canonical_devices import PushUnregisterParams
    _require(connection, "session:control")
    parsed = _parse(PushUnregisterParams, params)
    _own_device(connection, parsed.device_id)
    removed = await asyncio.to_thread(_storage, device_registry.clear_push_token, _root(connection),
                                      parsed.device_id)
    return {"removed": removed}


def handlers(connection):
    return {"devices.list": partial(devices_list, connection), "devices.forget": partial(devices_forget, connection),
            "push.register": partial(push_register, connection),
            "push.unregister": partial(push_unregister, connection)}
