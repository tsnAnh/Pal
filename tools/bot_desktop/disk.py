from __future__ import annotations

import shutil
from pathlib import Path
from typing import Optional

_MIB = 1024 * 1024
LOW_FREE_MB = 2048
CRITICAL_FREE_MB = 512
LOW_USED_PCT = 90
CRITICAL_USED_PCT = 97
LEVELS = ("normal", "low", "critical")


def level_for(free_mb: int, used_pct: int) -> str:
    if free_mb < CRITICAL_FREE_MB or used_pct >= CRITICAL_USED_PCT:
        return "critical"
    if free_mb < LOW_FREE_MB or used_pct >= LOW_USED_PCT:
        return "low"
    return "normal"


def disk_status(path: Optional[Path] = None) -> Optional[dict[str, object]]:
    from hermes_constants import get_hermes_home

    try:
        usage = shutil.disk_usage(path or get_hermes_home())
    except OSError:
        return None
    free_mb, total_mb = usage.free // _MIB, usage.total // _MIB
    used_pct = round(100 * usage.used / usage.total) if usage.total else 0
    return {"level": level_for(free_mb, used_pct), "free_mb": free_mb, "total_mb": total_mb, "used_pct": used_pct}
