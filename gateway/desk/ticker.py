from __future__ import annotations

import asyncio
import logging
import threading
from pathlib import Path
from typing import Any, Optional

from gateway.desk.service import Desk
from gateway.desk.store import DB_NAME

logger = logging.getLogger(__name__)

TICK_SECONDS = 30.0
STARTUP_DELAY_SECONDS = 3.0


class _Nudge:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._event: Optional[asyncio.Event] = None

    def arm(self) -> asyncio.Event:
        with self._lock:
            self._loop = asyncio.get_running_loop()
            self._event = asyncio.Event()
            return self._event

    def disarm(self) -> None:
        with self._lock:
            self._loop = self._event = None

    def fire(self) -> None:
        with self._lock:
            loop, event = self._loop, self._event
        if loop is not None and event is not None:
            loop.call_soon_threadsafe(event.set)


_nudge = _Nudge()


def nudge_ticker() -> None:
    _nudge.fire()


async def tick_homes(runner: Any, booted: set[Path]) -> None:
    from gateway.run import _async_profile_runtime_scope, _cron_profile_gate, _cron_tick_profile_homes
    for name, home in _cron_tick_profile_homes(runner.config):
        home = Path(home)
        if not (home / DB_NAME).exists() or not _cron_profile_gate(name, home):
            continue
        try:
            async with _async_profile_runtime_scope(home):
                desk = Desk(home, runner=runner, profile=name)
                if home not in booted:
                    await desk.recover_stranded()
                    booted.add(home)
                await desk.tick()
        except Exception:
            logger.warning("Desk tick failed for profile %s", name, exc_info=True)


async def run_ticker(runner: Any, interval: float = TICK_SECONDS) -> None:
    await asyncio.sleep(STARTUP_DELAY_SECONDS)
    wake = _nudge.arm()
    booted: set[Path] = set()
    try:
        while runner._running:
            await tick_homes(runner, booted)
            try:
                await asyncio.wait_for(wake.wait(), timeout=interval)
            except TimeoutError:
                pass
            wake.clear()
    finally:
        _nudge.disarm()
