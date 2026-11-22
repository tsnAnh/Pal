from __future__ import annotations

import threading
from typing import Any

from gateway.audience.admission import MemberRate, RateVerdict
from gateway.audience.posture import MEMBER_COMMANDS


def member_command_allowed(event: Any) -> bool:
    name = event.get_command()
    if name is None:
        return True
    from hermes_cli.commands import resolve_command
    command = resolve_command(name)
    return command is not None and command.name in MEMBER_COMMANDS


class MemberRates:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._by_profile: dict[str, MemberRate] = {}

    def check(self, profile_key: str, limit: int) -> RateVerdict:
        with self._lock:
            rate = self._by_profile.setdefault(profile_key, MemberRate())
        return rate.check(limit)
