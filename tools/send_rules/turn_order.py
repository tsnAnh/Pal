from __future__ import annotations

import contextlib
import threading
from collections.abc import Iterator
from contextvars import ContextVar
from typing import Any, Optional

from tools.routine_send import same_address
from tools.send_rules.destination import Destination
from tools.send_rules.order_text import Order, read_order


class TurnOrder:
    """One turn's send order: it covers a single send and any other input joining the turn withdraws it."""

    def __init__(self, order: Order) -> None:
        self.order = order
        self._lock = threading.Lock()
        self._used = False

    def covers(self, destination: Destination) -> bool:
        with self._lock:
            if self._used:
                return False
        if not self.order.places:
            return True
        prefix = f"{destination.platform}:"
        return not destination.thread and any(
            same_address(written.removeprefix(prefix), spelled)
            for written in self.order.places for spelled in destination.places)

    def spend(self, destination: Destination) -> bool:
        if not self.covers(destination):
            return False
        with self._lock:
            used, self._used = self._used, True
        return not used

    def spend_if_bare(self) -> None:
        """An order that names nowhere meant the next send, whatever cleared or stopped that send."""
        if not self.order.places:
            self.withdraw()

    def withdraw(self) -> None:
        with self._lock:
            self._used = True


_current: ContextVar[Optional[TurnOrder]] = ContextVar("send_turn_order", default=None)


def current() -> Optional[TurnOrder]:
    return _current.get()


@contextlib.contextmanager
def opened(live: Any, words: Optional[str]) -> Iterator[None]:
    """Bind the order in ``words``, the owner's typed message that opens this turn of ``live``."""
    order = read_order(words) if words else None
    held = None if order is None else TurnOrder(order)
    live.send_order = held
    token = _current.set(held)
    try:
        yield
    finally:
        if held is not None:
            held.withdraw()
        _current.reset(token)
        live.send_order = None


def void(live: Any) -> None:
    held = getattr(live, "send_order", None)
    if held is not None:
        held.withdraw()
