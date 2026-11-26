from __future__ import annotations

import os
import platform
from importlib import metadata

from scripts.memory_bench.tokens import ENCODING


def load_average() -> tuple[float, ...] | None:
    return os.getloadavg() if hasattr(os, "getloadavg") else None


def package_versions() -> dict[str, str]:
    found = {
        distribution.metadata["Name"]: distribution.version
        for distribution in metadata.distributions()
        if distribution.metadata["Name"]
    }
    return dict(sorted(found.items(), key=lambda entry: entry[0].lower()))


def machine_info(load_at_start: tuple[float, ...] | None) -> dict:
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "load_average_start": load_at_start,
        "load_average_end": load_average(),
        "tokenizer": ENCODING,
        "packages": package_versions(),
    }
