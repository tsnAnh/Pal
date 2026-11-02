from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Iterable


def dotted_key(*parts: str) -> str:
    return ".".join(part.replace(".", "\\.") for part in parts)


Edit = Callable[[dict], "dict[str, Any]"]


def edit_config_keys(config_path: Path, edit: Edit) -> dict[str, Any]:
    from hermes_cli import config as config_mod
    from hermes_cli.config_backend import write_config_keys

    with config_mod._CONFIG_LOCK:
        current = config_mod.require_readable_config_before_write(config_path)
        updates = edit(current)
        if updates:
            write_config_keys(config_path, updates)
        return updates


def name_list(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value] if value.strip() else []
    if isinstance(value, (list, tuple, set, frozenset)):
        return [str(v).strip() for v in value if isinstance(v, str) and v.strip()]
    return []


def _skills_section(config: dict) -> dict:
    section = config.get("skills")
    return section if isinstance(section, dict) else {}


def skill_list_updates(
    config: dict, *, enable: Iterable[str] = (), disable_add: Iterable[str] = (),
    disable_remove: Iterable[str] = (), enable_remove: Iterable[str] = (), drop_enabled_key: bool = False,
    prune_empty: bool = False,
) -> dict[str, Any]:
    section = _skills_section(config)
    disabled = name_list(section.get("disabled"))
    enabled = name_list(section.get("enabled"))
    new_disabled = sorted((set(disabled) | set(disable_add)) - set(disable_remove) - set(enable))
    new_enabled = sorted((set(enabled) | set(enable)) - set(enable_remove) - set(disable_add))
    updates: dict[str, Any] = {}
    if prune_empty and not new_disabled:
        if "disabled" in section:
            updates["skills.disabled"] = None
    elif new_disabled != sorted(set(disabled)) or ("disabled" not in section and new_disabled):
        updates["skills.disabled"] = new_disabled
    if drop_enabled_key:
        if "enabled" in section:
            updates["skills.enabled"] = None
    elif new_enabled != sorted(set(enabled)) or ("enabled" not in section and new_enabled):
        updates["skills.enabled"] = new_enabled
    return updates


def update_skill_lists(config_path: Path, **changes: Any) -> dict[str, Any]:
    return edit_config_keys(config_path, lambda config: skill_list_updates(config, **changes))
