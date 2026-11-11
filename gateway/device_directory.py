from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from gateway import device_connectors, device_registry
from gateway.device_actions import clean_text, connector_info
from gateway.device_tools import DEVICE_KINDS, live_device_ids
from tui_gateway.contracts.canonical_device import DeviceConnectorState as ConnectorState

KIND_NAMES = {"mac": "Mac", "ios": "iPhone"}


@dataclass(frozen=True, slots=True)
class DeviceView:
    device_id: str
    label: str
    kind: str
    type: str
    model: str
    os: str
    online: bool
    last_seen_at: float
    connectors: dict[str, ConnectorState]


@dataclass(frozen=True, slots=True)
class Resolution:
    device: DeviceView | None = None
    code: str = ""
    message: str = ""
    candidates: tuple[DeviceView, ...] = ()


def type_of(kind: str, model: str) -> str:
    if kind == "ios" and model.lower().startswith("ipad"):
        return "other"
    return KIND_NAMES.get(kind, "other")


def iso(stamp: float) -> str:
    return datetime.fromtimestamp(stamp, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def relative(stamp: float, now: float) -> str:
    seconds = max(0, int(now - stamp))
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit} ago"
    return "just now"


def last_seen_text(view: DeviceView, now: float) -> str:
    return "now" if view.online else f"{iso(view.last_seen_at)} ({relative(view.last_seen_at, now)})"


def snapshot(home: Path, authority, now: float | None = None) -> list[DeviceView]:
    stamp = time.time() if now is None else now
    known = device_connectors.device_kinds(home)
    root = device_registry.install_root(authority.profile_id)
    live = live_device_ids(authority, stamp, DEVICE_KINDS)
    views = []
    for record in device_registry.list_devices(root):
        if record.device_id not in known or record.kind not in KIND_NAMES:
            continue
        online = record.device_id in live
        statuses = device_connectors.statuses(home, record.device_id)
        views.append(DeviceView(
            device_id=record.device_id, label=clean_text(record.label, 100), kind=record.kind,
            type=type_of(record.kind, record.model), model=clean_text(record.model, 100),
            os=clean_text(record.os, 100), online=online,
            last_seen_at=stamp if online else record.last_seen_at,
            connectors={status.connector.value: status.state for status in statuses
                        if status.state is not ConnectorState.OFF}))
    return views


def describe(view: DeviceView, now: float) -> dict:
    row = {"device_id": view.device_id, "name": view.label, "type": view.type,
           "status": "online" if view.online else "offline", "last_seen_at": iso(view.last_seen_at),
           "last_seen": last_seen_text(view, now),
           "capabilities": {name: state.value for name, state in sorted(view.connectors.items())}}
    if view.model:
        row["model"] = view.model
    if view.os:
        row["os"] = view.os
    return row


def _listing(views, now: float) -> str:
    return "; ".join(f"{view.label} ({view.type}, {'online' if view.online else 'offline'}, "
                     f"last seen {last_seen_text(view, now)})" for view in views) or "none"


def resolve(views: list[DeviceView], name: str, now: float) -> Resolution:
    wanted = " ".join(name.split())
    if not wanted:
        return Resolution(code="invalid_args", message="Pass `device` as the device's name or device_id.")
    by_id = [view for view in views if view.device_id == wanted]
    if by_id:
        return Resolution(device=by_id[0])
    matches = [view for view in views if " ".join(view.label.split()).casefold() == wanted.casefold()]
    if len(matches) == 1:
        return Resolution(device=matches[0])
    if matches:
        return Resolution(
            code="ambiguous_device", candidates=tuple(matches),
            message=f"More than one device is named \"{clean_text(wanted, 100)}\": {_listing(matches, now)}. "
                    "Ask the user which one they mean, then pass its device_id.")
    return Resolution(
        code="device_not_found", candidates=tuple(views),
        message=f"No logged-in device is named \"{clean_text(wanted, 100)}\". Available devices: "
                f"{_listing(views, now)}. Ask the user which device they mean.")


def capability_title(connector: str) -> str:
    from tui_gateway.contracts.canonical_device import DeviceConnectorId
    return connector_info(DeviceConnectorId(connector)).title
