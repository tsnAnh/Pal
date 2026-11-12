from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import parse_qs, urlparse

MAX_PASTE_CHARS = 4096
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
_FIELDS = ("code", "state", "error", "iss")


class RedirectPasteError(ValueError):
    pass


@dataclass(frozen=True, repr=False)
class PastedRedirect:
    code: str | None
    state: str
    error: str | None
    iss: str | None

    def __repr__(self) -> str:
        return "PastedRedirect(<redacted>)"


def _query_of(text: str, expected_redirect: str) -> str:
    if "://" not in text:
        return text.removeprefix("?")
    parsed = urlparse(text)
    expected = urlparse(expected_redirect)
    try:
        port = parsed.port
    except ValueError:
        raise RedirectPasteError("That address is not the sign-in redirect.") from None
    if (parsed.scheme != "http" or (parsed.hostname or "").lower() not in LOOPBACK_HOSTS
            or parsed.username is not None or parsed.password is not None
            or port != expected.port or parsed.path.rstrip("/") != expected.path.rstrip("/")):
        raise RedirectPasteError("That address is not the sign-in redirect.")
    return parsed.query


def parse_pasted_redirect(raw: object, *, expected_redirect: str) -> PastedRedirect:
    if not isinstance(raw, str):
        raise RedirectPasteError("Paste the address the browser ended on.")
    text = raw.strip()
    if not text or len(text) > MAX_PASTE_CHARS:
        raise RedirectPasteError("Paste the address the browser ended on.")
    found = parse_qs(_query_of(text, expected_redirect), keep_blank_values=True)
    if any(len(found.get(name, ())) > 1 for name in _FIELDS):
        raise RedirectPasteError("That address repeats a sign-in value.")
    values = {name: (found[name][0] or None) if name in found else None for name in _FIELDS}
    if not values["state"]:
        raise RedirectPasteError("That address has no sign-in state.")
    if not values["code"] and not values["error"]:
        raise RedirectPasteError("That address has no sign-in result.")
    return PastedRedirect(values["code"], values["state"], values["error"], values["iss"])
