from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional

from gateway.audience.model import Audience
from gateway.audience.posture import audience_of_key
from gateway.desk.policy import TurnFacts

DEFAULT_ASK_TIMEOUT_MINUTES = 1440
DEFAULT_DECISION_TIMEOUT_MINUTES = 4320
MIN_ASK_MINUTES = 5


@dataclass(frozen=True)
class OwnerContact:
    platform: str
    scope_id: str
    user_id: str
    conversation_id: Optional[str]


@dataclass(frozen=True)
class DeskSettings:
    ask_timeout_minutes: int
    decision_timeout_minutes: int


def _positive_int(value: Any, default: int) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else default


def desk_settings() -> DeskSettings:
    from hermes_cli.config import read_raw_config_readonly
    block = read_raw_config_readonly().get("desk")
    block = block if isinstance(block, dict) else {}
    return DeskSettings(_positive_int(block.get("ask_timeout_minutes"), DEFAULT_ASK_TIMEOUT_MINUTES),
                        _positive_int(block.get("decision_timeout_minutes"), DEFAULT_DECISION_TIMEOUT_MINUTES))


def clamped_wait_minutes(requested: Any, settings: DeskSettings) -> int:
    if not isinstance(requested, int) or isinstance(requested, bool):
        return settings.ask_timeout_minutes
    return max(MIN_ASK_MINUTES, min(requested, settings.ask_timeout_minutes))


def _home_channel(platform: str) -> dict:
    from gateway.platforms._shared import platform_gate_env
    from hermes_cli.config import read_raw_config_readonly
    platforms = read_raw_config_readonly().get("platforms")
    block = platforms.get(platform) if isinstance(platforms, dict) else None
    configured = block.get("home_channel") if isinstance(block, dict) else None
    home = configured if isinstance(configured, dict) else {}
    from_env = platform_gate_env(f"{platform.upper()}_HOME_CHANNEL")
    if from_env and from_env != home.get("chat_id"):
        return {"chat_id": from_env}
    return home


def _first_allowed_user(platform: str) -> str:
    from gateway.platform_env import authz_field
    from gateway.platforms._shared import platform_gate_env
    name = authz_field(platform, "allowed_users_env") or ""
    for user_id in platform_gate_env(name).split(","):
        if user_id.strip() and user_id.strip() != "*":
            return user_id.strip()
    return ""


def owner_contact(platform: str, scope_id: str = "") -> Optional[OwnerContact]:
    home = _home_channel(platform)
    user_id = str(home.get("user_id") or "") or _first_allowed_user(platform)
    if not user_id:
        return None
    conversation = str(home.get("chat_id") or "") or None
    return OwnerContact(platform, scope_id or str(home.get("scope_id") or ""), user_id, conversation)


def turn_facts(platform: str) -> Optional[TurnFacts]:
    from gateway.session_context import bound_session_key, current_turn_event, get_session_env
    cron = get_session_env("HERMES_CRON_SESSION") == "1"
    if not cron and get_session_env("HERMES_SESSION_PLATFORM") != platform:
        return None
    contact = owner_contact(platform)
    if contact is None:
        return None
    event = current_turn_event()
    report = contact.conversation_id
    if cron or event is None:
        return TurnFacts(Audience.OWNER, True, False, False, frozenset(), frozenset(), contact.user_id, report)
    actor = get_session_env("HERMES_SESSION_ACTOR_ID")
    return TurnFacts(
        audience=audience_of_key(bound_session_key()), internal=bool(event.internal),
        actor_is_owner=bool(actor) and actor == contact.user_id,
        carries_member_content=bool(event.carries_member_content),
        named_user_ids=frozenset(event.named_user_ids), named_conversation_ids=frozenset(event.named_conversation_ids),
        owner_id=contact.user_id, report_conversation_id=report)
