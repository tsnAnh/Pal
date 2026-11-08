from __future__ import annotations

import logging
import threading
from pathlib import Path

logger = logging.getLogger(__name__)
DEFAULT_PRIMARY = "default"
_write_lock = threading.Lock()


def _config_path() -> Path:
    from hermes_constants import get_default_hermes_root

    return get_default_hermes_root() / "config.yaml"


def _configured_name() -> str | None:
    from hermes_cli.config_effective import load_user_config_effective
    from hermes_cli.profiles import normalize_profile_name

    section = load_user_config_effective(_config_path()).get("bot_mode")
    configured = section.get("primary_profile") if isinstance(section, dict) else None
    if not isinstance(configured, str) or not configured.strip():
        return None
    try:
        return normalize_profile_name(configured)
    except ValueError:
        return None


def primary_profile_name() -> str:
    from hermes_cli.profiles import profile_exists

    name = _configured_name()
    return name if name is not None and profile_exists(name) else DEFAULT_PRIMARY


def refuse_deleting_primary(canon: str) -> str:
    if canon != DEFAULT_PRIMARY and canon == primary_profile_name():
        raise ValueError(f"Cannot delete '{canon}': it is the primary bot. Make another bot primary first.")
    return canon


def follow_rename(old: str, new: str) -> None:
    if _configured_name() != old:
        return
    try:
        set_primary_profile(new)
    except OSError:
        logger.warning("Renamed the primary bot but could not move the primary pointer", exc_info=True)


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
