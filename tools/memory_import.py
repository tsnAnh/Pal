from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

from tools.memory_tool_store import FAILURE_CLASS, MemoryStore

MAX_IMPORT_CHARS = 64_000
MAX_IMPORT_ENTRIES = 400
MAX_ENTRY_CHARS = 600
TARGETS = ("memory", "user")

_BULLET = re.compile(r"^\s*(?:[-*•●◦‣]+|\d{1,3}[.)])\s+")
_DATE_PREFIX = re.compile(r"^\s*[\[(]?\d{4}-\d{2}-\d{2}(?:[T ][0-9:.]+Z?)?[\])]?\s*[:\-–—]?\s+")
_HEADING = re.compile(r"^\s*(?:#{1,6}\s|[-=_*]{3,}\s*$)")
_NO_CONTENT = re.compile(r"^[\W_]*$")


class MemoryImportError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass
class MemoryImportReport:
    target: str
    candidates: int = 0
    added: int = 0
    duplicates: int = 0
    too_long: int = 0
    blocked: int = 0
    over_budget: int = 0
    usage: str = ""
    entry_count: int = 0


def _fingerprint(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().strip(".!;,").casefold()


def split_entries(text: str) -> list[str]:
    entries = []
    for raw in text.splitlines():
        if not raw.strip() or _HEADING.match(raw):
            continue
        line = _DATE_PREFIX.sub("", _BULLET.sub("", raw, count=1), count=1)
        line = re.sub(r"\s+", " ", line).strip()
        if line and not _NO_CONTENT.match(line):
            entries.append(line)
    return entries


def _failure_kind() -> Optional[str]:
    kind = FAILURE_CLASS.get()
    return kind if kind in {"over_budget", "scan_blocked"} else None


def import_memory_text(text: str, target: str, store: MemoryStore) -> MemoryImportReport:
    if target not in TARGETS:
        raise MemoryImportError("invalid_target", "target must be 'memory' or 'user'")
    if not isinstance(text, str) or not text.strip():
        raise MemoryImportError("empty", "Paste the text to import.")
    if len(text) > MAX_IMPORT_CHARS:
        raise MemoryImportError("too_large", f"That is more than {MAX_IMPORT_CHARS:,} characters; import it in parts.")
    if not store.target_enabled(target):
        raise MemoryImportError("disabled", "Memory is turned off for this bot.")
    entries = split_entries(text)
    if len(entries) > MAX_IMPORT_ENTRIES:
        raise MemoryImportError("too_many", f"That is more than {MAX_IMPORT_ENTRIES} entries; import it in parts.")

    report = MemoryImportReport(target=target, candidates=len(entries))
    store.load_from_disk()
    seen = {_fingerprint(entry) for entry in store._entries_for(target)}
    pending = []
    for entry in entries:
        key = _fingerprint(entry)
        if key in seen:
            report.duplicates += 1
        elif len(entry) > MAX_ENTRY_CHARS:
            report.too_long += 1
        else:
            seen.add(key)
            pending.append(entry)

    for index, entry in enumerate(pending):
        response = store.add(target, entry)
        if response.get("success"):
            report.added += 1
            continue
        kind = _failure_kind()
        if kind == "scan_blocked":
            report.blocked += 1
        elif kind == "over_budget":
            report.over_budget += len(pending) - index
            break
        else:
            raise MemoryImportError("write_failed", str(response.get("error") or "Could not save to memory."))
    report.usage = store._usage(target)
    report.entry_count = len(store._entries_for(target))
    return report
