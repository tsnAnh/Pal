from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from hermes_cli.shared_catalog import BOT_FLAG_KEYS, merge_server, split_bot_secrets


@dataclass(frozen=True)
class EditorSave:
    bot_entries: dict[str, dict] = field(default_factory=dict)
    publish: dict[str, dict] = field(default_factory=dict)
    changed_shared: list[str] = field(default_factory=list)
    dropped_shared: list[str] = field(default_factory=list)


def _opt_in(cfg: dict, shared: dict, present: bool) -> dict | None:
    override = {k: v for k, v in cfg.items() if k not in BOT_FLAG_KEYS and shared.get(k) != v}
    flags = {k: cfg[k] for k in BOT_FLAG_KEYS if k in cfg}
    if not present and cfg.get("enabled", True) is False and not override:
        return None
    return {"enabled": cfg.get("enabled", True), **flags, **override}


def plan_editor_save(submitted: dict[str, Any], current: Any, definitions: dict[str, dict]) -> EditorSave:
    current = current if isinstance(current, dict) else {}
    bot_entries: dict[str, dict] = {}
    publish: dict[str, dict] = {}
    changed: list[str] = []
    for name, cfg in submitted.items():
        shared = definitions.get(name)
        if shared is None or not isinstance(cfg, dict):
            publish[name] = cfg
            continue
        entry = current.get(name)
        effective = merge_server(shared, entry if isinstance(entry, dict) else {})
        if split_bot_secrets(cfg)[0] != split_bot_secrets(effective)[0]:
            changed.append(name)
            publish[name] = cfg
        elif (opt_in := _opt_in(cfg, shared, name in current)) is not None:
            bot_entries[name] = opt_in
    dropped = sorted(n for n in definitions if n in current and n not in submitted)
    return EditorSave(bot_entries, publish, sorted(changed), dropped)
