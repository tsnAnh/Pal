from __future__ import annotations

import functools
import logging
import os

logger = logging.getLogger("run_agent")

_KIND_NAMES = {"darwin": "macOS", "win32": "Windows", "linux": "Linux"}


@functools.cache
def machine_line() -> str:
    try:
        from hermes_platform.host.summary import summary
        facts = summary()["machine"]
    except Exception:
        logger.debug("machine hint: host summary unavailable", exc_info=True)
        return ""
    family = facts.get("os_family", "")
    parts = [" ".join(part for part in (_KIND_NAMES.get(family, family), facts.get("native_arch", "")) if part)]
    if facts.get("cpu_model"):
        parts.append(f"CPU {facts['cpu_model']}")
    if cores := os.cpu_count():
        parts.append(f"{cores} cores")
    if facts.get("ram_gb"):
        parts.append(f"{facts['ram_gb']} GB RAM")
    if facts.get("container"):
        parts.append("inside a container")
    parts = [part for part in parts if part]
    return f"Machine: {', '.join(parts)}" if parts else ""
