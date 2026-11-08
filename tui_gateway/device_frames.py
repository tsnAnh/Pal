from __future__ import annotations

from tui_gateway.contracts.canonical_device import DeviceToolCancelPayload, DeviceToolRequestPayload


def request_frame(payload: DeviceToolRequestPayload) -> dict:
    return {"jsonrpc": "2.0", "method": "event",
            "params": {"type": "device.tool.request", "payload": payload.model_dump(mode="json", exclude_none=True)}}


def cancel_frame(payload: DeviceToolCancelPayload) -> dict:
    return {"jsonrpc": "2.0", "method": "event",
            "params": {"type": "device.tool.cancel", "payload": payload.model_dump(mode="json")}}
