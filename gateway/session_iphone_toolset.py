import json
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
