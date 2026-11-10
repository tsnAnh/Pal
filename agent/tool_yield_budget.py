from __future__ import annotations

import contextlib
import logging
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from numbers import Real
from typing import Any, Optional

from hermes_cli.config_defaults_bot_mode import BOT_MODE_DEFAULTS
from tools.interrupt import YieldReason, request_yield

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class YieldPolicy:
    background_after_s: float


def resolve_yield_policy(agent: Any, config: Optional[dict]) -> Optional[YieldPolicy]:
    from tools.bot_mode_dm import message_agent_authorized

    if not message_agent_authorized(agent):
        return None
    section = (config or {}).get("bot_mode")
    default = BOT_MODE_DEFAULTS["background_after_seconds"]
    value = section.get("background_after_seconds", default) if isinstance(section, dict) else default
    if isinstance(value, bool) or not isinstance(value, Real) or value < 0:
        logger.warning("bot_mode.background_after_seconds must be a number of seconds >= 0; using %s", default)
        value = default
    return YieldPolicy(float(value)) if value > 0 else None


def active_yield_policy(agent: Any) -> Optional[YieldPolicy]:
    policy = getattr(agent, "yield_policy", None)
    author = getattr(agent, "_turn_author", None)
    if policy is None or (isinstance(author, dict) and author.get("is_bot")):
        return None
    return policy


class BatchYieldBudget:
    def __init__(self, agent: Any, policy: YieldPolicy, excluded_seconds: Callable[[], float]) -> None:
        self._agent, self._policy, self._excluded_seconds = agent, policy, excluded_seconds
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._started = time.monotonic()
        self._thread = threading.Thread(target=self._run, name="tool-yield-budget", daemon=True)  # health: allow HX012 -- only signals worker thread ids, reads no profile state

    def arm(self) -> None:
        self._thread.start()

    def cancel(self) -> None:
        with self._lock:
            self._stop.set()
        self._thread.join(timeout=1)

    def _remaining(self) -> float:
        return self._policy.background_after_s + self._excluded_seconds() - (time.monotonic() - self._started)

    def _run(self) -> None:
        while not self._stop.is_set():
            remaining = self._remaining()
            if remaining <= 0:
                self._fire()
                return
            self._stop.wait(timeout=remaining)

    def _fire(self) -> None:
        agent = self._agent
        with self._lock:
            if self._stop.is_set():
                return
            with agent._tool_worker_threads_lock:
                for tid in agent._tool_worker_threads:
                    request_yield(tid, YieldReason.BUDGET)


@contextlib.contextmanager
def batch_yield_budget(agent: Any, excluded_seconds: Callable[[], float]) -> Iterator[None]:
    policy = active_yield_policy(agent)
    if policy is None:
        yield
        return
    budget = BatchYieldBudget(agent, policy, excluded_seconds)
    budget.arm()
    try:
        yield
    finally:
        budget.cancel()
