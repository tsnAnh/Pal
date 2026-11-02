from __future__ import annotations

from pathlib import Path
from typing import Any

from hermes_cli.profile_yaml import PROFILE_YAML, load_profile_yaml, update_profile_yaml

ONBOARDING_KEY = "onboarding_pending"


def is_onboarding_pending(meta: dict[str, Any]) -> bool:
    return meta.get(ONBOARDING_KEY) is True


def _set_flag(profile_dir: Path, pending: bool) -> bool:
    if not Path(profile_dir).is_dir():
        return False

    def mutate(data: dict[str, Any]) -> bool:
        if is_onboarding_pending(data) == pending:
            return False
        if pending:
            data[ONBOARDING_KEY] = True
        else:
            data.pop(ONBOARDING_KEY, None)
        return True

    return update_profile_yaml(profile_dir, mutate)


def mark_onboarding_pending(profile_dir: Path) -> bool:
    return _set_flag(profile_dir, True)


def clear_onboarding_pending(profile_dir: Path) -> bool:
    return _set_flag(profile_dir, False)


def read_onboarding_pending(profile_dir: Path) -> bool:
    data = load_profile_yaml(Path(profile_dir) / PROFILE_YAML)
    return bool(data) and is_onboarding_pending(data)
