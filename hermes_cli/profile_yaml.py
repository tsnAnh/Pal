from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Optional

logger = logging.getLogger(__name__)

PROFILE_YAML = "profile.yaml"
_LOCK_NAME = ".profile.yaml.lock"


def profile_yaml_lock(profile_dir: Path):
    from tools.skill_usage import skill_file_lock

    return skill_file_lock(Path(profile_dir) / _LOCK_NAME)


def load_profile_yaml(path: Path) -> Optional[dict[str, Any]]:
    if not path.is_file():
        return {}
    import hermes_yaml as yaml

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8-sig")) or {}
    except Exception:
        logger.warning("profile.yaml at %s is unreadable", path, exc_info=True)
        return None
    return data if isinstance(data, dict) else None


def update_profile_yaml(
    profile_dir: Path,
    mutate: Callable[[dict[str, Any]], Optional[bool]],
    *,
    overwrite_unreadable: bool = False,
) -> bool:
    from utils import atomic_yaml_write

    profile_dir = Path(profile_dir)
    path = profile_dir / PROFILE_YAML
    with profile_yaml_lock(profile_dir):
        data = load_profile_yaml(path)
        if data is None:
            if not overwrite_unreadable:
                return False
            data = {}
        if mutate(data) is False:
            return False
        atomic_yaml_write(path, data, sort_keys=False)
    return True
