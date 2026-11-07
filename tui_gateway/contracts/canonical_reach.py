from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Payload, Result
from .registry import canonical_method, event

ClientKind = Literal["desktop", "ios", "tui", "cli", "web"]
AttentionState = Literal["foreground", "background", "idle"]


class ClientHelloParams(Params):
    kind: ClientKind
    device_id: str = Field(pattern=r"^[A-Za-z0-9-]{8,64}$")
    label: str = Field(min_length=1, max_length=40)
    app_version: str = Field(default="", max_length=32)
    accepts_offers: bool = False
    attention: AttentionState = "foreground"


class ClientHelloResult(Result):
    recorded: bool
    same_host: bool


canonical_method("client.hello", params=ClientHelloParams, result=ClientHelloResult,
                 doc="Declare this connection's client device; resent on every reconnect, replaces the "
                     "previous declaration. same_host is derived by the server, never claimed.")


class ClientAttentionParams(Params):
    state: AttentionState


class RecordedResult(Result):
    recorded: bool


canonical_method("client.attention", params=ClientAttentionParams, result=RecordedResult,
                 doc="Report a foreground/background/idle change; recorded is false before client.hello.")


class ReachOutcomeParams(Params):
    offer_id: str = Field(min_length=1, max_length=64)
    outcome: Literal["shown", "acted", "dismissed"]


canonical_method("reach.outcome", params=ReachOutcomeParams, result=RecordedResult,
                 doc="Report what the user did with a reach.offer; outcomes only move forward, an unknown "
                     "offer answers recorded false.")


class ReachOfferPayload(Payload):
    offer_id: str
    kind: Literal["notify", "suggest"]
    domain: str
    title: str
    body: str
    session_id: str | None = None


event("reach.offer", ReachOfferPayload,
      doc="A proactive offer to alert on; answer reach.outcome shown within 15s once presented.")
