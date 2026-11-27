from __future__ import annotations

import logging
import threading
import time
from collections.abc import Mapping
from typing import Optional

from gateway.session_context import current_turn_event
from tools import outbound_send_grant
from tools.approval_context import get_current_session_key
from tools.mcp_action_gate import approver_present
from tools.send_rules import store
from tools.send_rules.destination import Destination, destination_of
from tools.skill_provenance import is_background_review

logger = logging.getLogger(__name__)

_MAX_LABEL_CHARS = 200
_passes_lock = threading.Lock()
_passes: dict[tuple[str, str, str, str], float] = {}


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


def _pass_key(tool_name: str, destination: str) -> tuple[str, str, str, str]:
    return get_current_session_key(), str(store.rules_path()), tool_name, destination


def _first_gate_already_counted(key: tuple[str, str, str, str], gate: str) -> bool:
    now = time.monotonic()
    with _passes_lock:
        for stale in [k for k, expires in _passes.items() if expires <= now]:
            del _passes[stale]
        if gate == outbound_send_grant.MCP_GATE:
            return _passes.pop(key, None) is not None
        _passes[key] = now + outbound_send_grant.GATE_PASS_TTL_SECONDS
        return False


def answered_on_card(tool_name: str, destination: str) -> None:
    """The owner just answered the draft card, so a rule saved by that answer is not "used" at the second gate."""
    _first_gate_already_counted(_pass_key(tool_name, destination), outbound_send_grant.DRAFT_GATE)


def allows(tool_name: str, destination: str, *, gate: str = outbound_send_grant.DRAFT_GATE) -> bool:
    """One send that passes both gates is counted once. A rule file that cannot be used allows nothing."""
    key = _pass_key(tool_name, destination)
    try:
        if store.find(tool_name, destination) is None:
            return False
        if _first_gate_already_counted(key, gate):
            return True
        rule = store.use(tool_name, destination)
    except (OSError, ValueError) as exc:
        logger.warning("send rules could not be used (%s); the owner is asked", type(exc).__name__)
        return False
    if rule is None:
        return False
    logger.info("send allowed by rule bot=%s destination=%s", rule.profile, rule.destination_label)
    return True
