from __future__ import annotations

import threading
import time
from collections import deque
from collections.abc import Callable
from enum import Enum

from gateway.audience.model import Admission, AdmissionKind, AudiencePolicy, AudiencePolicyKind, SenderFacts

RATE_WINDOW_SECONDS = 3600.0


def decide_admission(
    owner_ok: bool, pending_ask: str | None, policy: AudiencePolicy, facts: SenderFacts | None,
) -> Admission:
    if owner_ok:
        return Admission(AdmissionKind.OWNER)
    if pending_ask is not None:
        return Admission(AdmissionKind.REPLY, facts, pending_ask)
    if policy.admits(facts):
        return Admission(AdmissionKind.MEMBER, facts)
    return Admission(AdmissionKind.REFUSED, needs_facts=facts is None and policy.kind is not AudiencePolicyKind.OWNER_ONLY)


class RateVerdict(Enum):
    ALLOWED = "allowed"
    NOTICE = "notice"
    SILENT = "silent"


class MemberRate:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._stamps: deque[float] = deque()
        self._noticed = False

    def check(self, limit: int) -> RateVerdict:
        now = self._clock()
        with self._lock:
            while self._stamps and now - self._stamps[0] >= RATE_WINDOW_SECONDS:
                self._stamps.popleft()
            if len(self._stamps) < limit:
                self._stamps.append(now)
                self._noticed = False
                return RateVerdict.ALLOWED
            if self._noticed:
                return RateVerdict.SILENT
            self._noticed = True
            return RateVerdict.NOTICE
