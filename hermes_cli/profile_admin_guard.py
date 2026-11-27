from __future__ import annotations

import secrets
import threading
import time
from contextlib import contextmanager
from typing import Callable, Iterator

CREATE_REFUSED_MESSAGE = "A bot can only be created in a turn the owner typed in the app, or from the Create Bot form."
CREATE_GRANT_ENV = "HERMES_SESSION_CREATE_GRANT"
CREATE_GRANT_TTL_SECONDS = 600

_grant_expiry: dict[str, float] = {}
_grant_lock = threading.Lock()


@contextmanager
def create_grant() -> Iterator[Callable[[], None]]:
    from gateway.session_context import scoped_create_grant
    grant = secrets.token_urlsafe(32)
    with _grant_lock:
        now = time.monotonic()
        for expired in [key for key, expiry in _grant_expiry.items() if expiry <= now]:
            del _grant_expiry[expired]
        _grant_expiry[grant] = now + CREATE_GRANT_TTL_SECONDS
    kept: list[str] = []
    try:
        with scoped_create_grant(grant):
            yield lambda: kept.append(grant)
    finally:
        if not kept:
            spend_create_grant(grant)


def spend_create_grant(grant: object) -> bool:
    if not isinstance(grant, str):
        return False
    with _grant_lock:
        expiry = _grant_expiry.pop(grant, None)
    return expiry is not None and time.monotonic() < expiry
