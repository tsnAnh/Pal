"""The log of a "teach a skill" demonstration: structured browser events, never video or keystrokes.

The owner takes the bot's screen and does a browser workflow once; the capture (``teach_capture``) reports
what happened and every event passes through :meth:`TeachLog.add`, the single privacy gate: values typed
into password, one-time-code and card fields (or fields that name themselves as secrets) are replaced by
``SECRET_MARKER`` before they reach disk, URLs keep scheme, host and path only, and the log is bounded in
events and bytes. The capture is untrusted (it reports what page script and the browser said), so this
module re-derives every decision from the raw attributes instead of trusting a ``secret`` flag.

Layout: ``<HERMES_HOME>/bot-desktop/teach/<teach_id>/`` (0700) holding ``events.jsonl`` (0600) and, once the
recording became a draft, ``meta.json`` (``teach_draft``). The directory is deleted when the draft is saved
or discarded; :func:`purge_orphans` reaps what a crashed gateway left behind.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlsplit

from agent.redact import redact_sensitive_text
from hermes_constants import get_hermes_home, secure_parent_dir

SECRET_MARKER = "<typed secret>"
ID_MARKER = "<id>"

MAX_EVENTS = 300
MAX_LOG_BYTES = 48 * 1024
MAX_VALUE_CHARS = 200
MAX_NAME_CHARS = 120
MAX_SELECTOR_CHARS = 200
MAX_PATH_CHARS = 200
MAX_FILENAME_CHARS = 120
ORPHAN_MAX_AGE_SECONDS = 3600

KINDS = frozenset({"navigate", "click", "type", "key", "download"})
HTTP_SCHEMES = frozenset({"http", "https"})
ALLOWED_KEYS = frozenset({"Enter", "Escape"})

_SECRET_AUTOCOMPLETE = re.compile(r"(^|\s)(one-time-code|current-password|new-password|cc-[a-z-]+)(\s|$)", re.IGNORECASE)
_SECRET_WORDS = re.compile(
    r"password|passcode|passphrase|passwd|(?<![a-z])(pass|pwd|pw|pin|otp|cvv|cvc|ssn)(?![a-z])|one[- ]?time|"
    r"verification code|security code|card number|credit card|social security|secret|api[ _-]?key|token",
    re.IGNORECASE)
_OPAQUE_SEGMENT = re.compile(r"^[A-Za-z0-9_-]{8,}$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_ID = re.compile(r"[a-z0-9-]{8,64}")


def teach_root() -> Path:
    return get_hermes_home() / "bot-desktop" / "teach"


def valid_teach_id(teach_id: object) -> bool:
    return isinstance(teach_id, str) and _ID.fullmatch(teach_id) is not None


def teach_dir(teach_id: str) -> Path:
    if not valid_teach_id(teach_id):
        raise ValueError("invalid teach id")
    return teach_root() / teach_id


def _text(value: object, limit: int) -> str:
    return _CONTROL.sub(" ", str(value if value is not None else "")).strip()[:limit]


def _opaque_segment(segment: str) -> bool:
    """A path segment that is probably a token, a share or reset id, or an address: it mixes letters and digits at
    length, or contains ``@``."""
    if "@" in segment:
        return True
    return bool(_OPAQUE_SEGMENT.match(segment)) and any(c.isdigit() for c in segment) and any(c.isalpha() for c in segment)


def strip_url(raw: object) -> Optional[str]:
    """``scheme://host[:port]/path`` or ``None`` for anything that is not a web page: query, fragment and
    credentials are dropped, and an opaque path segment (a reset or share token) becomes ``<id>``."""
    try:
        parts = urlsplit(str(raw or "").strip())
        scheme, host, port = parts.scheme.lower(), parts.hostname, parts.port
    except ValueError:
        return None
    if scheme not in HTTP_SCHEMES or not host:
        return None
    path = "/".join(ID_MARKER if _opaque_segment(seg) else seg for seg in parts.path.split("/"))
    netloc = host if port is None else f"{host}:{port}"
    return f"{scheme}://{netloc}{_CONTROL.sub('', path)[:MAX_PATH_CHARS]}"


def _truthy(value: object) -> bool:
    return value is True or str(value).strip().lower() in {"true", "1"}


def is_secret_field(target: dict[str, Any]) -> bool:
    """A field whose typed value must never be recorded: a password input, an autocomplete token for a
    one-time code, password or card data, or a field that names itself as one of those."""
    if str(target.get("input_type") or "").lower() == "password":
        return True
    if _SECRET_AUTOCOMPLETE.search(str(target.get("autocomplete") or "")):
        return True
    hints = " ".join(str(target.get(k) or "") for k in ("name", "label", "placeholder", "field_id", "field_name"))
    return bool(_SECRET_WORDS.search(hints))


def _target(raw: object) -> dict[str, Any]:
    src = raw if isinstance(raw, dict) else {}
    out = {
        "role": _text(src.get("role"), 40),
        "name": redact_sensitive_text(_text(src.get("name"), MAX_NAME_CHARS), force=True),
        "selector": _text(src.get("selector"), MAX_SELECTOR_CHARS),
    }
    return {k: v for k, v in out.items() if v}


def _typed_value(raw: dict[str, Any], field: dict[str, Any]) -> str:
    if _truthy(raw.get("secret")) or is_secret_field(field):
        return SECRET_MARKER
    return redact_sensitive_text(_text(raw.get("value"), MAX_VALUE_CHARS), force=True)


def sanitize(raw: object) -> Optional[dict[str, Any]]:
    """The loggable form of one reported event, or ``None`` when it is not worth keeping or not safe to."""
    if not isinstance(raw, dict) or raw.get("kind") not in KINDS:
        return None
    kind = raw["kind"]
    if kind == "navigate":
        url = strip_url(raw.get("url"))
        return {"kind": kind, "url": url} if url else None
    if kind == "download":
        url, name = strip_url(raw.get("url")), os.path.basename(_text(raw.get("filename"), 4 * MAX_FILENAME_CHARS))
        return {"kind": kind, "filename": name[:MAX_FILENAME_CHARS], **({"url": url} if url else {})}
    if kind == "key":
        key = raw.get("key")
        return {"kind": kind, "key": key} if key in ALLOWED_KEYS else None
    target = _target(raw.get("target"))
    if not target:
        return None
    page = strip_url(raw.get("page"))
    event: dict[str, Any] = {"kind": kind, "target": target, **({"page": page} if page else {})}
    if kind == "type":
        event["value"] = _typed_value(raw, raw["target"])
    return event


def _private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def open_private(path: str | bytes | os.PathLike, flags: int) -> int:
    return os.open(path, flags, 0o600)


class TeachLog:
    """Append-only, bounded, private event log of one recording. Thread-safe: the capture thread adds while
    an RPC thread reads."""

    def __init__(self, teach_id: str, *, clock=time.monotonic):
        self.teach_id = teach_id
        self.directory = teach_dir(teach_id)
        self.path = self.directory / "events.jsonl"
        self._clock = clock
        self._started = clock()
        self._lock = threading.Lock()
        self._bytes = 0
        self._count = 0
        self.dropped = 0
        self.truncated = False
        self._closed = False
        self._last_url: Optional[str] = None
        teach_root().parent.mkdir(parents=True, exist_ok=True)
        _private_dir(teach_root())
        secure_parent_dir(teach_root())
        _private_dir(self.directory)
        with open(self.path, "a", encoding="utf-8", opener=open_private):
            pass

    @property
    def count(self) -> int:
        with self._lock:
            return self._count

    def close(self) -> None:
        """No event is accepted after this: a capture that outlives its recording (a stuck flush) must not write
        into a log that was already collected or deleted."""
        with self._lock:
            self._closed = True

    def add(self, raw: object) -> bool:
        event = sanitize(raw)
        if event is None:
            return False
        with self._lock:
            if self._closed:
                return False
            if event["kind"] == "navigate" and event["url"] == self._last_url:
                return False
            line = json.dumps({"seq": self._count + 1, "t": round(self._clock() - self._started, 1), **event},
                              ensure_ascii=False, separators=(",", ":"))
            size = len(line.encode("utf-8")) + 1
            if self._count >= MAX_EVENTS or self._bytes + size > MAX_LOG_BYTES:
                self.dropped += 1
                self.truncated = True
                return False
            with open(self.path, "a", encoding="utf-8", opener=open_private) as fh:
                fh.write(line + "\n")
            self._count += 1
            self._bytes += size
            if event["kind"] == "navigate":
                self._last_url = event["url"]
        return True

    def events(self) -> list[dict[str, Any]]:
        return read_events(self.directory)

    def delete(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)


def read_events(directory: Path) -> list[dict[str, Any]]:
    try:
        lines = (directory / "events.jsonl").read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    events = []
    for line in lines:
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict):
            events.append(item)
    return events


def delete_events(teach_id: str) -> None:
    try:
        (teach_dir(teach_id) / "events.jsonl").unlink()
    except FileNotFoundError:
        pass


def delete_all(teach_id: str) -> None:
    shutil.rmtree(teach_dir(teach_id), ignore_errors=True)


def purge_orphans(*, keep: frozenset[str] = frozenset(), now: Optional[float] = None,
                  max_age: float = ORPHAN_MAX_AGE_SECONDS) -> list[str]:
    """Delete recordings that never became a draft (no ``meta.json``) and are older than ``max_age``: a
    gateway that died mid-recording leaves its log behind, and it must not outlive the session that owned it.
    ``keep`` names the recordings a live recorder still owns."""
    cutoff = (time.time() if now is None else now) - max_age
    removed = []
    try:
        entries = list(teach_root().iterdir())
    except OSError:
        return removed
    for entry in entries:
        try:
            if (entry.name in keep or not entry.is_dir() or (entry / "meta.json").exists()
                    or entry.stat().st_mtime > cutoff):
                continue
        except OSError:
            continue
        shutil.rmtree(entry, ignore_errors=True)
        removed.append(entry.name)
    return removed
