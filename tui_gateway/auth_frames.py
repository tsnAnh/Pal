from __future__ import annotations

from tui_gateway.contracts.canonical_auth import AuthRequiredPayload, AuthResolvedPayload


def required_frame(payload: AuthRequiredPayload) -> dict:
    return {"jsonrpc": "2.0", "method": "event",
            "params": {"type": "auth.required", "payload": payload.model_dump(mode="json", exclude_none=True)}}


def resolved_frame(payload: AuthResolvedPayload) -> dict:
    return {"jsonrpc": "2.0", "method": "event",
            "params": {"type": "auth.resolved", "payload": payload.model_dump(mode="json")}}
