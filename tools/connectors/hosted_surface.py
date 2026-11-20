from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Optional, Sequence


@dataclass(frozen=True)
class HostedSurface:
    available: Callable[[], bool]
    names: Callable[[], Optional[set[str]]]
    reissue: Callable[[Any, Sequence[str], Optional[str]], None]


_installed: Optional[HostedSurface] = None


def install(surface: HostedSurface) -> None:
    global _installed
    _installed = surface


def installed() -> bool:
    return _installed is not None


def available() -> bool:
    return _installed is not None and bool(_installed.available())


def names() -> Optional[set[str]]:
    return _installed.names() if _installed is not None else None


def reissue(operation: Any, stale: Sequence[str], initiator: Optional[str]) -> None:
    if _installed is None:
        raise RuntimeError("no hosted connector surface is installed")
    _installed.reissue(operation, stale, initiator)
