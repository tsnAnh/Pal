from __future__ import annotations

import logging
import threading
import time
from collections.abc import Mapping
from typing import Optional

from gateway.session_context import current_turn_event
from hermes_constants import get_hermes_home
from tools import outbound_send_grant
from tools.approval_card_text import owner_language, rule_line
from tools.approval_context import get_current_session_key
from tools.details_bubble import post_line
from tools.mcp_action_gate import approver_present
from tools.send_rules import store, turn_order
from tools.send_rules.destination import Destination, destination_of
from tools.skill_provenance import is_background_review

logger = logging.getLogger(__name__)

_MAX_LABEL_CHARS = 200
_passes_lock = threading.Lock()
_passes: dict[tuple[str, ...], float] = {}


def _owner_typed_this_turn() -> bool:
    if not approver_present() or is_background_review():
        return False
    from gateway.session_ingress import admission_author  # importable whenever a viewer turn is running
    if (admission_author.get() or {}).get("is_bot"):
        return False
    return not getattr(current_turn_event(), "carries_member_content", False)


def owner_turn_destination(tool_name: str, args: Mapping,
                           identity: Optional[Mapping] = None) -> Optional[Destination]:
    return destination_of(tool_name, args, identity) if _owner_typed_this_turn() else None


def offer(tool_name: str, destination: Optional[Destination], recipient: str,
          channel: str) -> Optional[store.SendRuleCandidate]:
    label = " ".join(recipient.split())[:_MAX_LABEL_CHARS]
    if destination is None or recipient.strip() != destination.shown:
        return None
    return store.SendRuleCandidate(tool_name, destination.signature, label, f"Send to {label} via {channel}")


def _pass_key(tool_name: str, destination: Destination) -> tuple[str, ...]:
    return (get_current_session_key(), str(store.rules_path()), tool_name, destination.signature,
            destination.call_digest)


def _leave_pass(key: tuple[str, ...]) -> None:
    now = time.monotonic()
    with _passes_lock:
        for stale in [k for k, expires in _passes.items() if expires <= now]:
            del _passes[stale]
        _passes[key] = now + outbound_send_grant.GATE_PASS_TTL_SECONDS


def _take_pass(key: tuple[str, ...]) -> bool:
    with _passes_lock:
        return _passes.pop(key, 0.0) > time.monotonic()


def allows(tool_name: str, destination: str) -> bool:
    """A rule file that cannot be used allows nothing, so the owner is asked."""
    try:
        if store.find(tool_name, destination) is None:
            return False
        rule = store.use(tool_name, destination)
    except (OSError, ValueError) as exc:
        logger.warning("send rules could not be used (%s); the owner is asked", type(exc).__name__)
        return False
    if rule is None:
        return False
    logger.info("send allowed by rule bot=%s destination=%s", rule.profile, rule.destination_label)
    return True


def _bot_name() -> str:
    from hermes_cli.profiles import read_profile_meta
    meta = read_profile_meta(get_hermes_home())
    return meta["bot_title"] or meta["display_name"] or store.current_profile()


def _save_standing_rule(candidate: store.SendRuleCandidate, channel: str) -> None:
    """The rule exists only once the owner has been told about it in the chat."""
    if not post_line(rule_line(owner_language(), _bot_name(), candidate.destination_label, channel)):
        logger.warning("send rule not saved: no chat line could be posted")
        return
    try:
        store.remember(candidate)
    except (OSError, ValueError) as exc:
        logger.warning("send rule not saved (%s); this send is still approved", type(exc).__name__)
        post_line(rule_line(owner_language(), _bot_name(), candidate.destination_label, channel, saved=False))


def _ordered(destination: Destination, candidate: store.SendRuleCandidate, channel: str) -> bool:
    turn = turn_order.current()
    if turn is None or not turn.spend(destination):
        return False
    logger.info("send allowed by owner order bot=%s destination=%s", store.current_profile(),
                candidate.destination_label)
    if turn.order.standing:
        _save_standing_rule(candidate, channel)
    return True


def _spend_bare_order() -> None:
    if (turn := turn_order.current()) is not None:
        turn.spend_if_bare()


def cleared(tool_name: str, destination: Optional[Destination], recipient: str, channel: str, *, gate: str) -> bool:
    """True when a saved rule or this turn's order lets the send through with no card. An order also needs the
    card to be able to show the destination. A send that passes both gates is cleared once: the draft gate leaves
    a short-lived pass for that exact call, which the action gate takes."""
    if destination is None:
        _spend_bare_order()
        return False
    key = _pass_key(tool_name, destination)
    if gate == outbound_send_grant.MCP_GATE and _take_pass(key):
        return True
    if allows(tool_name, destination.signature):
        _spend_bare_order()
    else:
        candidate = offer(tool_name, destination, recipient, channel)
        if candidate is None or not _ordered(destination, candidate, channel):
            _spend_bare_order()
            return False
    if gate == outbound_send_grant.DRAFT_GATE:
        _leave_pass(key)
    return True


def answered_on_card(tool_name: str, destination: Optional[Destination]) -> None:
    """The owner just answered the draft card, so a rule saved by that answer is not "used" at the action gate."""
    if destination is None:
        return
    try:
        saved = store.find(tool_name, destination.signature) is not None
    except (OSError, ValueError):
        return
    if saved:
        _leave_pass(_pass_key(tool_name, destination))


def already_allowed(destination: Optional[Destination], candidate: Optional[store.SendRuleCandidate]) -> bool:
    """Whether this send would need no card, without spending or counting anything."""
    if destination is None or candidate is None:
        return False
    try:
        if store.find(candidate.tool, destination.signature) is not None:
            return True
    except (OSError, ValueError):
        return False
    turn = turn_order.current()
    return turn is not None and turn.covers(destination)
