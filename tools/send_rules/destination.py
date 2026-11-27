from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Optional

from gateway.outbound.targets import _parse_target_ref
from tools import routine_send
from tools.bot_mode_drafts import _carries_secret, flatten_args

_LIST_SEPARATORS = (",", ";")
_HANDLE_OR_ID = re.compile(
    r"[#@!][^\s#@!]\S*|[^\s@]+@[^\s@]+\.[^\s@]+|[+-]?\d{6,}|(?=[A-Z]*\d)[A-Z][A-Z0-9]{7,}")
_EVERYONE = frozenset({"all", "channel", "everyone", "here"})


@dataclass(frozen=True)
class Destination:
    signature: str
    shown: str
    platform: str
    places: frozenset[str]
    thread: str
    call_digest: str


def _exact_address(value: Any) -> Optional[str]:
    if isinstance(value, list):
        return _exact_address(value[0]) if len(value) == 1 else None
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None
    text = str(value).strip()
    if not text.isprintable() or unicodedata.normalize("NFKC", text) != text:
        return None
    return None if any(separator in text for separator in _LIST_SEPARATORS) else text


def _cannot_come_to_mean_another(tool_name: str, platform: str, place: str) -> bool:
    """A bare name resolved at send time can come to mean somebody else; ``send_message`` even prefix-matches one."""
    if tool_name == "send_message":
        return _parse_target_ref(platform, place)[2]
    return _HANDLE_OR_ID.fullmatch(place) is not None and place.lstrip("#@!").casefold() not in _EVERYONE


def destination_of(tool_name: str, args: Mapping, identity: Optional[Mapping] = None) -> Optional[Destination]:
    """Fails closed on a field nobody classified: it could add a recipient or switch the account. ``identity``
    holds the stable ids behind a destination shown by a reusable name."""
    call = routine_send.send_call(tool_name, dict(args))
    if call is None or _carries_secret(*call.texts):
        return None
    places = set().union(*call.destinations)
    if len(places) != 1 or not all(places):
        return None
    place = places.pop()
    if identity is None and not _cannot_come_to_mean_another(tool_name, call.platform, place):
        return None
    flat = flatten_args(dict(args))
    if any(routine_send.is_attachment_arg(key) for key in flat) or flat.get("action", "send") != "send":
        return None
    address = {key: _exact_address(value) for key, value in flat.items()
               if not routine_send.is_text_arg(key) and value not in (None, "", [])}
    if None in address.values():
        return None
    signature = json.dumps({"address": address, "identity": dict(identity or {})}, sort_keys=True,
                           ensure_ascii=False, separators=(",", ":"))
    shown = address["target"] if tool_name == "send_message" else place
    digest = hashlib.sha256(json.dumps(flat, sort_keys=True, default=repr).encode()).hexdigest()
    return Destination(signature, shown, call.platform, frozenset({place}), call.thread, digest)
