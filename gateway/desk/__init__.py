"""The owner desk: durable items that only the bot's owner settles, kept per profile home.

- ``model``: the data shapes. ``DeskItem`` (an ask waiting on someone's reply, a hand-off a member wants the
  owner to run, or a send the owner lane may not make alone), its ``ItemState`` machine, ``Origin`` (the
  session an outcome wakes) and ``OwnerCard`` (the platform-neutral card an adapter renders for the owner).
- ``policy``: pure rules. ``outbound_decision`` (send now or ask the owner) and ``match_reply`` (which open
  ask a sender's message answers).
- ``store``: ``DeskStore``, sqlite under the profile home, every move a compare-and-set on state and revision.
- ``owner``: the owner contact and turn facts read from the running turn.
- ``service``: ``Desk``, the one object that opens, decides, claims, expires and executes items. Import it from
  ``gateway.desk.service``: it pulls in the session stack, which tools that only need the model must not pay for.
- ``delivery``: wakes an item's origin session and renders the texts owners and members read.
- ``runtime``: the gateway-side entry points (reply claims, card clicks, session-boundary cancels).
- ``ticker``: the supervised loop that posts cards, expires items and redelivers outcomes per served profile.
"""

from __future__ import annotations

from gateway.desk.model import (
    TERMINAL_STATES,
    AskPayload,
    DeskItem,
    HandoffPayload,
    ItemKind,
    ItemState,
    Origin,
    OwnerCard,
    Recipient,
    SendPayload,
    item_id_for_call,
    send_digest,
)
from gateway.desk.owner import (
    OwnerContact,
    clamped_wait_minutes,
    desk_settings,
    owner_contact,
    turn_facts,
)
from gateway.desk.policy import AMBIGUOUS_REPLY, Outbound, TurnFacts, match_reply, outbound_decision
from gateway.desk.store import DeskStore

__all__ = [
    "AMBIGUOUS_REPLY",
    "TERMINAL_STATES",
    "AskPayload",
    "DeskItem",
    "DeskStore",
    "HandoffPayload",
    "ItemKind",
    "ItemState",
    "Origin",
    "Outbound",
    "OwnerCard",
    "OwnerContact",
    "Recipient",
    "SendPayload",
    "TurnFacts",
    "clamped_wait_minutes",
    "desk_settings",
    "item_id_for_call",
    "match_reply",
    "outbound_decision",
    "owner_contact",
    "send_digest",
    "turn_facts",
]
