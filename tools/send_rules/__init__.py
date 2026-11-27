"""What lets a send go out with no card: a saved "always allow" rule, or the owner's order in this turn.

``destination`` turns a send call into the destination both are matched on, ``store`` keeps one profile's rules on
disk, ``order_text`` reads an order out of the owner's words, ``turn_order`` holds it for one turn, and ``gate``
is what the send gates, the approval card and the clarify tool call.
"""

from tools.send_rules.destination import Destination, destination_of
from tools.send_rules.gate import (
    allows,
    already_allowed,
    answered_on_card,
    cleared,
    offer,
    owner_turn_destination,
)
from tools.send_rules.store import SendRule, SendRuleCandidate, list_rules, remember, revoke

__all__ = [
    "Destination",
    "SendRule",
    "SendRuleCandidate",
    "allows",
    "already_allowed",
    "answered_on_card",
    "cleared",
    "destination_of",
    "list_rules",
    "offer",
    "owner_turn_destination",
    "remember",
    "revoke",
]
