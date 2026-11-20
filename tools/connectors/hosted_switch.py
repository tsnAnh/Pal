from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

_FALSE_STRINGS = frozenset({"false", "0", "no", "off", ""})


def _is_on(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() not in _FALSE_STRINGS
    return bool(value)


def hosted_enabled() -> bool:
    from hermes_cli.config_backend import ConfigBackendUnavailable

    try:
        from hermes_cli.config import load_config_readonly

        section = (load_config_readonly() or {}).get("connectors")
        return _is_on(section.get("hosted", True)) if isinstance(section, dict) else True
    except (Exception, ConfigBackendUnavailable) as exc:  # health: allow BLE001 -- fail closed: an unreadable config must not open the hosted surface
        logger.debug("connectors.hosted unreadable, hosted connectors treated as off: %s", exc)
        return False
