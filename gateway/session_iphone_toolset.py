import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


def with_iphone(authority, policy, config, enabled, session_id):
    if enabled is None or 'iphone' in enabled or policy.safe_mode:
        return enabled
    live = getattr(authority, 'sessions', {}).get(session_id)
    granted = getattr(live, 'iphone_toolset', None)
    if granted is None:
        granted = _chat_has_a_phone(authority, policy, config, session_id)
        if live is not None:
            live.iphone_toolset = granted
    return [*enabled, 'iphone'] if granted else enabled


def _terminal_chat(policy) -> bool:
    """Cron, kanban and a2a sessions are stored under their own source; a ``-t`` pick is the whole selection."""
    return policy.source == 'cli' and 'toolsets' not in json.loads(policy.request_json)


def _bot_chat(authority, session_id) -> bool:
    db = getattr(authority, 'db', None)
    if db is None:
        return False
    row = db.get_session(db.get_compression_tip(session_id) or session_id)
    from gateway.session_local_migration import bot_chat_row
    return row is not None and bot_chat_row(row)


def _chat_has_a_phone(authority, policy, config, session_id) -> bool:
    from agent.skill_utils import parse_config_string_list
    if 'iphone' in parse_config_string_list((config.get('agent') or {}).get('disabled_toolsets')):
        return False
    if not (_terminal_chat(policy) or _bot_chat(authority, session_id)):
        return False
    from gateway import device_connectors
    return device_connectors.any_enabled(Path(authority.profile_id))


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
    NO_CONNECTOR_ON = 'no_connector_on'


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


GRANTED_KINDS = frozenset({SessionKind.IOS, SessionKind.BOT_CHAT, SessionKind.CLI, SessionKind.DESKTOP})


def decide_grant(facts: SessionFacts) -> GrantDecision:
    raise NotImplementedError


def session_facts(authority, policy, config, session_id) -> SessionFacts:
    raise NotImplementedError


def tui_session_facts(platform: str, config) -> SessionFacts:
    raise NotImplementedError
