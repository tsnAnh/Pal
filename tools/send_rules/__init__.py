"""The owner's "always allow" rules: one bot, one send tool, one exact destination.

``destination`` turns a send call into the destination a rule is keyed by, ``store`` keeps one profile's rules on
disk, and ``gate`` is what the send gates and the approval card call.
"""

from tools.send_rules.destination import Destination, destination_of
from tools.send_rules.gate import allows, answered_on_card, offer, owner_turn_destination
from tools.send_rules.store import SendRule, SendRuleCandidate, list_rules, remember, revoke

__all__ = [
    "Destination",
    "SendRule",
    "SendRuleCandidate",
    "allows",
    "answered_on_card",
    "destination_of",
    "list_rules",
    "offer",
    "owner_turn_destination",
    "remember",
    "revoke",
]
