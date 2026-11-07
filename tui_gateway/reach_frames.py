from __future__ import annotations

from tui_gateway.contracts.canonical_reach import ReachOfferPayload

TITLE_LIMIT = 120
BODY_LIMIT = 280


def _clip(text: str, limit: int) -> str:
    flat = " ".join((text or "").split())
    return flat if len(flat) <= limit else flat[: limit - 1].rstrip() + "…"


def offer_frame(*, offer_id: str, kind: str, domain: str, title: str, body: str,
                session_id: str | None = None) -> dict:
    payload = ReachOfferPayload(
        offer_id=offer_id, kind=kind, domain=domain, title=_clip(title, TITLE_LIMIT),
        body=_clip(body, BODY_LIMIT), session_id=session_id).model_dump(exclude_none=True)
    return {"jsonrpc": "2.0", "method": "event", "params": {"type": "reach.offer", "payload": payload}}
