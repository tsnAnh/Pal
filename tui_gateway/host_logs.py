"""Bounded, redacted tail of one allow-listed Pal log for ``host.logs.tail``."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

MAX_LINES = 500
MAX_BYTES = 64 * 1024
MAX_LINE_CHARS = 2000
MAX_SCAN_BYTES = 4 * 1024 * 1024
CHUNK = 64 * 1024
LOG_NAMES = ("gateway", "agent", "errors")
MASK = "[redacted]"

_KEY_NAME = r"[\w.-]*(?:key|token|secret|passw(?:or)?d|credential|auth)[\w.-]*"
_PATTERNS = (
    re.compile(r"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{16,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{16,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"),
    re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(rf"(?i)(\b{_KEY_NAME}[\"']?\s*[:=]\s*[\"']?)[A-Za-z0-9+/_=-]{{20,}}"),
    re.compile(r"(\b[a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"),
    re.compile(r"\b[0-9a-fA-F]{40,}\b"),
)


def redact(text: str) -> str:
    for index, pattern in enumerate(_PATTERNS):
        if index == 4 or index == 5:
            text = pattern.sub(lambda m: f"{m.group(1)}{MASK}", text)
        elif index == 6:
            text = pattern.sub(lambda m: f"{m.group(1)}{MASK}@", text)
        else:
            text = pattern.sub(MASK, text)
    from agent.redact import redact_sensitive_text
    return redact_sensitive_text(text, force=True, redact_url_credentials=True)


@dataclass(frozen=True)
class Tail:
    lines: list[str]
    has_more: bool
    truncated: bool
    available: bool


def log_path(name: str):
    if name not in LOG_NAMES:
        return None
    from hermes_cli.logs import log_file_path
    return log_file_path(name)


def _read_newest(path, wanted: int) -> tuple[list[bytes], bool]:
    with open(path, "rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        end, data, scanned = size, b"", 0
        while end > 0 and data.count(b"\n") <= wanted and scanned < MAX_SCAN_BYTES:
            start = max(0, end - CHUNK)
            handle.seek(start)
            data = handle.read(end - start) + data
            scanned += end - start
            end = start
        lines = data.split(b"\n")
        if lines and lines[-1] == b"":
            lines.pop()
        complete = end == 0
        if not complete and lines:
            lines = lines[1:]
        return lines, complete


def tail(name: str, lines: int, skip: int, *, path=None) -> Tail:
    path = path if path is not None else log_path(name)
    if path is None:
        raise ValueError("unknown log")
    lines = max(1, min(int(lines), MAX_LINES))
    skip = max(0, int(skip))
    try:
        raw, complete = _read_newest(path, skip + lines)
    except FileNotFoundError:
        return Tail([], False, False, False)
    older = len(raw) - skip
    page = raw[max(0, older - lines):max(0, older)]
    has_more = older > lines or (not complete and older >= lines)
    decoded = [redact(line.decode("utf-8", "replace")[:MAX_LINE_CHARS]) for line in page]
    truncated = False
    while decoded and sum(len(line.encode()) + 1 for line in decoded) > MAX_BYTES:
        decoded.pop(0)
        truncated = True
    return Tail(decoded, has_more or truncated, truncated, True)
