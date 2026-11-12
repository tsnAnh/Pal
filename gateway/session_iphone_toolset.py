import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class SessionKind(Enum):
    IOS = 'ios'
    BOT_CHAT = 'bot_chat'
    CLI = 'cli'
    DESKTOP = 'desktop'
    OTHER = 'other'


class GrantReason(Enum):
    GRANTED = 'granted'
    KIND_NOT_ALLOWED = 'kind_not_allowed'
    EXPLICIT_PICK = 'explicit_pick'
    SAFE_MODE = 'safe_mode'
    DISABLED_BY_CONFIG = 'disabled_by_config'
    NO_REGISTERED_DEVICE = 'no_registered_device'


@dataclass(frozen=True, slots=True)
class SessionFacts:
    kind: SessionKind
    picked_toolsets: bool
    safe_mode: bool
    disabled_toolsets: frozenset[str]
    profile_home: Path


@dataclass(frozen=True, slots=True)
class GrantDecision:
    reason: GrantReason

    @property
    def granted(self) -> bool:
        return self.reason is GrantReason.GRANTED

    @property
    def can_flip(self) -> bool:
        return self.reason in (GrantReason.GRANTED, GrantReason.NO_REGISTERED_DEVICE)


GRANTED_KINDS = frozenset({SessionKind.IOS, SessionKind.BOT_CHAT, SessionKind.CLI, SessionKind.DESKTOP})


def decide_grant(facts: SessionFacts) -> GrantDecision:
    if facts.kind not in GRANTED_KINDS:
        return GrantDecision(GrantReason.KIND_NOT_ALLOWED)
    if facts.picked_toolsets:
        return GrantDecision(GrantReason.EXPLICIT_PICK)
    if facts.safe_mode:
        return GrantDecision(GrantReason.SAFE_MODE)
    if 'iphone' in facts.disabled_toolsets:
        return GrantDecision(GrantReason.DISABLED_BY_CONFIG)
    from gateway import device_connectors
    if not device_connectors.any_enabled(facts.profile_home):
        return GrantDecision(GrantReason.NO_REGISTERED_DEVICE)
    return GrantDecision(GrantReason.GRANTED)


def with_iphone(authority, policy, config, enabled, session_id):
    if enabled is None or 'iphone' in enabled:
        return enabled
    live = getattr(authority, 'sessions', {}).get(session_id)
    if getattr(live, 'iphone_toolset', None) is True:
        return [*enabled, 'iphone']
    decision = decide_grant(session_facts(authority, policy, config, session_id))
    if live is not None and (decision.granted or not decision.can_flip):
        live.iphone_toolset = decision.granted
    return [*enabled, 'iphone'] if decision.granted else enabled


def _bot_chat(authority, session_id) -> bool:
    db = getattr(authority, 'db', None)
    if db is None:
        return False
    row = db.get_session(db.get_compression_tip(session_id) or session_id)
    from gateway.session_local_migration import bot_chat_row
    return row is not None and bot_chat_row(row)


_POLICY_KINDS = {'ios': SessionKind.IOS, 'cli': SessionKind.CLI, 'gui': SessionKind.DESKTOP}


def session_facts(authority, policy, config, session_id) -> SessionFacts:
    from agent.skill_utils import parse_config_string_list
    bot_chat = _bot_chat(authority, session_id)
    kind = SessionKind.BOT_CHAT if bot_chat else _POLICY_KINDS.get(policy.source, SessionKind.OTHER)
    return SessionFacts(
        kind=kind,
        picked_toolsets=not bot_chat and 'toolsets' in json.loads(policy.request_json),
        safe_mode=policy.safe_mode,
        disabled_toolsets=frozenset(parse_config_string_list((config.get('agent') or {}).get('disabled_toolsets'))),
        profile_home=Path(authority.profile_id))
