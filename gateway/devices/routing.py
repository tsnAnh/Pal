from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from gateway.device_actions import ActionSpec
from gateway.device_directory import DeviceView, Resolution, capability_title, fold_name, last_seen_text, listing
from tui_gateway.contracts.canonical_device import DeviceConnectorState


@dataclass(frozen=True, slots=True)
class TypingDevice:
    kind: str
    label: str


def route(views: Sequence[DeviceView], spec: ActionSpec, typing: TypingDevice | None, now: float) -> Resolution:
    ready = [view for view in views if view.online and _capable(view, spec)]
    if len(ready) == 1:
        return Resolution(device=ready[0])
    if not ready:
        rows = "; ".join(_availability(view, spec, now) for view in views) or "No device is logged in"
        return Resolution(
            code="no_device_available", candidates=tuple(views),
            message=f"No device can do {spec.name} ({capability_title(spec.connector.value)}) right now, so nothing "
                    f"was started. {rows}.")
    typed = [view for view in ready if typing is not None and _is_typing(view, typing)]
    if len(typed) == 1:
        return Resolution(device=typed[0])
    return Resolution(
        code="needs_choice", candidates=tuple(ready),
        message=f"More than one of the user's devices can do {spec.name} right now: {listing(ready, now)}. Nothing "
                "was started. Ask the user once which of these to use (tell same-named ones apart by `model` and `os` "
                "in `devices`), then call again with `device` set to that device's device_id.")


def _capable(view: DeviceView, spec: ActionSpec) -> bool:
    state = view.connectors.get(spec.connector.value, DeviceConnectorState.OFF)
    return view.kind in spec.kinds and state is not DeviceConnectorState.OFF


def _is_typing(view: DeviceView, typing: TypingDevice) -> bool:
    return view.kind == typing.kind and fold_name(view.label) == fold_name(typing.label)


def _availability(view: DeviceView, spec: ActionSpec, now: float) -> str:
    presence = "online" if view.online else f"offline since {last_seen_text(view, now)}"
    row = f"{view.label} ({view.type}): {presence}"
    if _capable(view, spec):
        return row
    row = f"{row}, lacks {capability_title(spec.connector.value)}"
    if view.kind in spec.kinds:
        row = f"{row}, the user switched it off there, so do not ask again unless they bring it up"
    return row
