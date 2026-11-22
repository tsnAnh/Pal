from __future__ import annotations

import copy
import threading
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

from gateway.audience import AudiencePolicy
from tui_gateway.chat_install import StaleRevision

_LOCK = threading.Lock()


@dataclass(frozen=True)
class AudienceSettings:
    policy: AudiencePolicy
    revision: int


def _platform_block(config: dict[str, Any], platform_id: str) -> dict[str, Any]:
    platforms = config.get("platforms")
    block = platforms.get(platform_id) if isinstance(platforms, dict) else None
    return block if isinstance(block, dict) else {}


def _revision_of(raw: object) -> int:
    value = raw.get("revision") if isinstance(raw, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def read_audience(platform_id: str) -> AudienceSettings:
    from hermes_cli.config import read_raw_config_readonly
    raw = _platform_block(read_raw_config_readonly(), platform_id).get("audience")
    return AudienceSettings(AudiencePolicy.from_config(raw), _revision_of(raw))


def _audience_block(policy: AudiencePolicy, revision: int) -> dict[str, Any]:
    return {
        "policy": policy.kind.value, "members": sorted(policy.members), "include_restricted": policy.include_restricted,
        "member_turns_per_hour": policy.member_turns_per_hour, "revision": revision,
    }


def write_audience(platform_id: str, policy: AudiencePolicy, expected_revision: int) -> AudienceSettings:
    from hermes_cli.config import load_config, save_config
    with _LOCK:
        config = load_config()
        platforms = config.setdefault("platforms", {})
        platform = platforms.setdefault(platform_id, {})
        current = _revision_of(platform.get("audience"))
        if current != expected_revision:
            raise StaleRevision(platform_id)
        platform["audience"] = _audience_block(policy, current + 1)
        save_config(config)
        return AudienceSettings(policy, current + 1)


def read_home(platform_id: str):
    from gateway.config import HomeChannel
    from hermes_cli.config import read_raw_config_readonly
    raw = _platform_block(read_raw_config_readonly(), platform_id).get("home_channel")
    if not isinstance(raw, dict) or not raw.get("chat_id"):
        return None
    return HomeChannel.from_dict(raw)


def write_home(home) -> None:
    from gateway.config import persist_home_channel
    from hermes_cli.config import get_env_value, save_env_value
    persist_home_channel(home)
    env_name = f"{home.platform.value.upper()}_HOME_CHANNEL"
    if get_env_value(env_name):
        save_env_value(env_name, home.chat_id)


def _missing_leaves(present: object, wanted: dict[str, Any], path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], Any]]:
    present = present if isinstance(present, dict) else {}
    for key, value in wanted.items():
        if key not in present:
            yield (*path, key), value
        elif isinstance(value, dict) and isinstance(present[key], dict):
            yield from _missing_leaves(present[key], value, (*path, key))


def seed_missing(defaults: dict[str, Any]) -> bool:
    from hermes_cli.config import load_config, read_raw_config, save_config
    with _LOCK:
        missing = list(_missing_leaves(read_raw_config(), defaults))
        if not missing:
            return False
        config = load_config()
        for path, value in missing:
            slot = config
            for key in path[:-1]:
                nested = slot.get(key)
                if not isinstance(nested, dict):
                    nested = slot[key] = {}
                slot = nested
            slot[path[-1]] = copy.deepcopy(value)
        save_config(config)
        return True
