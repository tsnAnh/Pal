from __future__ import annotations

import threading
from pathlib import Path

DEFAULT_PRIMARY = "default"
_write_lock = threading.Lock()


def _config_path() -> Path:
    from hermes_constants import get_default_hermes_root

    return get_default_hermes_root() / "config.yaml"


def primary_profile_name() -> str:
    from hermes_cli.config_effective import load_user_config_effective
    from hermes_cli.profiles import normalize_profile_name, profile_exists

    section = load_user_config_effective(_config_path()).get("bot_mode")
    configured = section.get("primary_profile") if isinstance(section, dict) else None
    if not isinstance(configured, str) or not configured.strip():
        return DEFAULT_PRIMARY
    try:
        name = normalize_profile_name(configured)
    except ValueError:
        return DEFAULT_PRIMARY
    return name if profile_exists(name) else DEFAULT_PRIMARY


def set_primary_profile(name: str) -> str:
    from hermes_cli.config import atomic_config_replace, read_user_config_raw
    from hermes_cli.profiles import normalize_profile_name, profile_exists

    canon = normalize_profile_name(name)
    if not profile_exists(canon):
        raise FileNotFoundError(f"Profile '{canon}' does not exist.")
    path = _config_path()
    with _write_lock:
        config = read_user_config_raw(path)
        section = config.get("bot_mode")
        section = dict(section) if isinstance(section, dict) else {}
        if section.get("primary_profile") != canon:
            section["primary_profile"] = canon
            atomic_config_replace(path, {**config, "bot_mode": section})
    return canon
