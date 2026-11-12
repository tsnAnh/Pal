"""Parse the value an owner pastes after a loopback OAuth redirect failed to load in their browser.

The browser lands on the provider's registered ``http://127.0.0.1:<port>/...`` redirect, which no
device other than the gateway host can serve, and the owner pastes what is in the address bar. Accepted
shapes: the full redirect URL, the bare query (``code=..&state=..``, with or without ``?``), or just the
code and the state separated by whitespace, a comma or ``#``. The pasted text is never logged and is
not kept; callers hold only the :class:`Callback` it yields.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from urllib.parse import parse_qsl, urlsplit

MAX_PASTE_CHARS = 4096
_SINGLE_USE_KEYS = ("code", "state", "error", "error_description")
_PAIR_SPLIT = re.compile(r"[\s,#]+")


class CallbackError(Exception):
    """A paste that cannot complete the sign-in. ``retry`` is True when the same request may be answered again."""

    def __init__(self, code: str, message: str, *, retry: bool) -> None:
        super().__init__(code)
        self.code = code
        self.message = message
        self.retry = retry


@dataclass(frozen=True)
class Callback:
    code: str = field(repr=False)
    state: str = field(repr=False)


def _fields(query: str) -> dict[str, str]:
    seen: dict[str, str] = {}
    for key, value in parse_qsl(query, keep_blank_values=True, max_num_fields=32):
        if key in _SINGLE_USE_KEYS and key in seen:
            raise CallbackError("duplicate_param", "That address repeats a sign-in value. Copy it again from the browser.",
                                retry=True)
        seen.setdefault(key, value)
    return seen


def _same_redirect(pasted: str, redirect_uri: str) -> bool:
    got, want = urlsplit(pasted), urlsplit(redirect_uri)
    try:
        return (got.scheme == want.scheme and (got.hostname or "").lower() == (want.hostname or "").lower()
                and got.port == want.port and got.path == want.path and not got.username and not got.password)
    except ValueError:
        return False


def _query_of(text: str, redirect_uri: str) -> str:
    if "://" in text:
        if not _same_redirect(text, redirect_uri):
            raise CallbackError("wrong_address", "That address is not the one this sign-in ended on. Copy it again "
                                "from the browser's address bar.", retry=True)
        return urlsplit(text).query
    if "=" in text:
        return text.lstrip("?")
    pair = [part for part in _PAIR_SPLIT.split(text) if part]
    if len(pair) == 2:
        return f"code={pair[0]}&state={pair[1]}"
    raise CallbackError("unrecognized", "That doesn't look like the address from the browser. Copy the whole address "
                        "and paste it again.", retry=True)


def parse_callback(text: str, *, redirect_uri: str, state: str) -> Callback:
    """The code the paste carries, after the redirect, the state and the shape check out."""
    import hmac

    text = (text or "").strip()
    if not text or len(text) > MAX_PASTE_CHARS:
        raise CallbackError("unrecognized", "That doesn't look like the address from the browser. Copy the whole "
                            "address and paste it again.", retry=True)
    values = _fields(_query_of(text, redirect_uri))
    if values.get("error"):
        raise CallbackError("denied", "Sign-in was declined on the provider's page.", retry=False)
    given_state = values.get("state", "")
    if not given_state:
        raise CallbackError("missing_state", "That address has no sign-in check value. Copy the whole address and "
                            "paste it again.", retry=True)
    if not hmac.compare_digest(given_state.encode(), state.encode()):
        raise CallbackError("state_mismatch", "That address belongs to a different sign-in attempt. Use the one "
                            "from the page that just opened.", retry=True)
    code = values.get("code", "").strip()
    if not code:
        raise CallbackError("missing_code", "That address has no sign-in code. Copy it again once the page has "
                            "finished loading.", retry=True)
    return Callback(code=code, state=given_state)
