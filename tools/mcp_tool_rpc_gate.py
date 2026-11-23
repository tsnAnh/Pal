import asyncio
import contextlib
import contextvars
from collections import deque
from dataclasses import dataclass
from typing import AsyncIterator, Callable, Iterator, Optional


class RpcGate:
    def __init__(self, shared_allowed: Callable[[], bool] = lambda: False):
        self._shared_allowed = shared_allowed
        self._readers = 0
        self._writer = False
        self._pending_writers = 0
        self._waiters: deque[asyncio.Future] = deque()

    def locked(self) -> bool:
        return self._writer or self._readers > 0

    def _free_for(self, exclusive: bool) -> bool:
        if exclusive:
            return not self._writer and self._readers == 0
        return not self._writer and self._pending_writers == 0

    def _wake_all(self) -> None:
        waiters, self._waiters = self._waiters, deque()
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(None)

    async def _acquire(self, exclusive: bool) -> None:
        if exclusive:
            self._pending_writers += 1
        taken = False
        try:
            while not self._free_for(exclusive):
                waiter = asyncio.get_running_loop().create_future()
                self._waiters.append(waiter)
                try:
                    await waiter
                finally:
                    with contextlib.suppress(ValueError):
                        self._waiters.remove(waiter)
            if exclusive:
                self._writer = True
            else:
                self._readers += 1
            taken = True
        finally:
            if exclusive:
                self._pending_writers -= 1
            if not taken:
                self._wake_all()

    def _release(self, exclusive: bool) -> None:
        if exclusive:
            self._writer = False
        else:
            self._readers -= 1
        self._wake_all()

    @contextlib.asynccontextmanager
    async def _slot(self, exclusive: bool) -> AsyncIterator[None]:
        await self._acquire(exclusive)
        try:
            yield
        finally:
            self._release(exclusive)

    def exclusive(self):
        return self._slot(True)

    def shared(self):
        return self._slot(not self._shared_allowed())


@dataclass(frozen=True, eq=False)
class CallScope:
    context: contextvars.Context
    callbacks: tuple


class AmbiguousCall(Exception):
    pass


class InFlightCalls:
    def __init__(self) -> None:
        self._scopes: list[CallScope] = []

    @contextlib.contextmanager
    def track(self, context: contextvars.Context, callbacks: tuple) -> Iterator[CallScope]:
        scope = CallScope(context, callbacks)
        self._scopes.append(scope)
        try:
            yield scope
        finally:
            self._scopes.remove(scope)

    def attribute(self) -> Optional[CallScope]:
        if len(self._scopes) > 1:
            raise AmbiguousCall(len(self._scopes))
        return self._scopes[0] if self._scopes else None
