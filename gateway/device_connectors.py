from __future__ import annotations

import threading
import time
from dataclasses import dataclass
import json
from pathlib import Path

from gateway.device_actions import APPLE_KINDS, CONNECTOR_CATALOG, Connector, connector_info
from tui_gateway.contracts.canonical_device import DeviceConnectorState as ConnectorState
from tui_gateway.contracts.canonical_device import DeviceOsPermission as OsPermission
from utils import atomic_json_write

STOPPABLE = Connector.INPUT
FILE_NAME = "device_connectors.json"
SCHEMA_VERSION = 1
MAX_DEVICES = 16


class UnknownDevice(LookupError):
    pass


class StoreUnreadable(OSError):
    pass


@dataclass(frozen=True, slots=True)
class ConnectorStatus:
    connector: Connector
    title: str
    subtitle: str
    state: ConnectorState
    os_permission: OsPermission
    always_on: bool = False


_lock = threading.RLock()


def _path(home: Path) -> Path:
    return Path(home) / FILE_NAME


def _load(home: Path) -> dict:
    try:
        raw = json.loads(_path(home).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise StoreUnreadable(f"{FILE_NAME} cannot be read") from exc
    devices = raw.get("devices") if isinstance(raw, dict) and raw.get("version") == SCHEMA_VERSION else None
    if not isinstance(devices, dict):
        raise StoreUnreadable(f"{FILE_NAME} is not a version {SCHEMA_VERSION} store")
    return devices


def _save(home: Path, devices: dict) -> None:
    atomic_json_write(_path(home), {"version": SCHEMA_VERSION, "devices": devices}, mode=0o600)


def _enum_or(enum_type, value, default):
    try:
        return enum_type(value)
    except ValueError:
        return default


def _entry(device: dict, connector: Connector) -> dict:
    entry = (device.get("connectors") or {}).get(connector.value)
    return entry if isinstance(entry, dict) else {}


def _state(device: dict, info) -> ConnectorState:
    entry = _entry(device, info.connector)
    if info.connector is STOPPABLE:
        return ConnectorState.OFF if entry.get("stopped") is True else ConnectorState.ALLOWED
    if not info.on_by_default:
        return ConnectorState.ALLOWED
    stored = _enum_or(ConnectorState, entry.get("state"), ConnectorState.ASK)
    return ConnectorState.ASK if stored is ConnectorState.OFF else stored


def _settable(connector: Connector, state: ConnectorState) -> bool:
    if connector is STOPPABLE:
        return True
    info = connector_info(connector)
    return info.on_by_default and state is not ConnectorState.OFF


def kind_of(device: dict) -> str:
    kind = device.get("kind")
    return kind if isinstance(kind, str) and kind else "ios"


def _status(device: dict) -> list[ConnectorStatus]:
    kind = kind_of(device)
    return [ConnectorStatus(
        info.connector, info.title, info.subtitle,
        _state(device, info),
        _enum_or(OsPermission, _entry(device, info.connector).get("os_permission"), OsPermission.NOT_DETERMINED),
        True)
        for info in CONNECTOR_CATALOG if kind in info.kinds]


def register_device(home: Path, device_id: str, label: str, *, kind: str = "ios", now: float | None = None) -> None:
    stamp = time.time() if now is None else now
    with _lock:
        devices = _load(home)
        known = devices.get(device_id)
        record = known if isinstance(known, dict) else {"connectors": {}, "registered_at": stamp}
        record.update(label=label, kind=kind, last_seen_at=stamp)
        devices[device_id] = record
        for stale in sorted(devices, key=lambda key: devices[key].get("last_seen_at", 0))[: max(0, len(devices) - MAX_DEVICES)]:
            devices.pop(stale)
        _save(home, devices)


def known_device_ids(home: Path) -> list[str]:
    with _lock:
        return list(_load(home))


def statuses(home: Path, device_id: str) -> list[ConnectorStatus]:
    with _lock:
        device = _load(home).get(device_id)
    if not isinstance(device, dict):
        raise UnknownDevice(device_id)
    return _status(device)


def update(home: Path, device_id: str, connector: Connector, *, state: ConnectorState | None = None,
           os_permission: OsPermission | None = None) -> list[ConnectorStatus]:
    with _lock:
        devices = _load(home)
        device = devices.get(device_id)
        if not isinstance(device, dict):
            raise UnknownDevice(device_id)
        if state is not None and not _settable(connector, state):
            state = None
        if state is None and os_permission is None:
            return _status(device)
        connectors = device.setdefault("connectors", {})
        entry = dict(_entry(device, connector))
        if connector is STOPPABLE and state is not None:
            entry["stopped"] = state is ConnectorState.OFF
        elif state is not None:
            entry["state"] = state.value
        if os_permission is not None:
            entry["os_permission"] = os_permission.value
        connectors[connector.value] = entry
        _save(home, devices)
        return _status(device)


def open_devices(home: Path, connector: Connector) -> dict[str, ConnectorState]:
    with _lock:
        try:
            devices = _load(home)
        except StoreUnreadable:
            return {}
    states = {device_id: {status.connector: status.state for status in _status(device)}.get(connector)
              for device_id, device in devices.items() if isinstance(device, dict)}
    return {device_id: state for device_id, state in states.items()
            if state is not None and state is not ConnectorState.OFF}


def device_kinds(home: Path) -> dict[str, str]:
    with _lock:
        devices = _load(home)
    return {device_id: kind_of(device) for device_id, device in devices.items() if isinstance(device, dict)}


def any_enabled(home: Path) -> bool:
    with _lock:
        try:
            devices = _load(home)
        except StoreUnreadable:
            return False
    return any(status.state is not ConnectorState.OFF
               for device in devices.values() if isinstance(device, dict) for status in _status(device))

