"""The details bubble of an ask raised inside a running tool call (a draft approval).

The clarify tool is split before its turn is persisted (``tools/clarify_split.py``); an approval is
raised from inside the call, so the executor binds the agent's bubble sink for the call and the gate
posts what the owner must read through ``post_details`` before it asks. ``False`` means no bubble
could be shown, and the caller keeps the content in its card.
"""
from __future__ import annotations

import contextlib
import contextvars
from typing import Callable, Iterator, Optional

DetailsSink = Callable[[str], bool]
_sink: contextvars.ContextVar[Optional[DetailsSink]] = contextvars.ContextVar("details_bubble_sink", default=None)


@contextlib.contextmanager
def bound_details_sink(sink: Optional[DetailsSink]) -> Iterator[None]:
    token = _sink.set(sink)
    try:
        yield
    finally:
        _sink.reset(token)


def post_details(text: str) -> bool:
    sink = _sink.get()
    return bool(text.strip()) and sink is not None and sink(text)
