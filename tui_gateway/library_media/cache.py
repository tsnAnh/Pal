from __future__ import annotations

import base64
import contextlib
import json
import os
import tempfile
from pathlib import Path

from tui_gateway.contracts.library import LibraryPreviewReason as Reason

from .result import PreviewResult

CACHE_MAX_BYTES = 64_000_000
_ENTRY_SUFFIX = ".json"


class PreviewCache:
    """One JSON file per ``<asset id>-<mtime_ns>-<size>``: a changed file misses, old entries age out.
    Best effort: an unreadable or unwritable cache just means the preview is rendered again."""

    def __init__(self, root: Path, max_bytes: int = CACHE_MAX_BYTES):
        self._root = root
        self._max_bytes = max_bytes

    def _entry(self, asset_ref: str, mtime_ns: int, size: int) -> Path:
        return self._root / f"{asset_ref}-{mtime_ns:x}-{size:x}{_ENTRY_SUFFIX}"

    def get(self, asset_ref: str, mtime_ns: int, size: int) -> PreviewResult | None:
        entry = self._entry(asset_ref, mtime_ns, size)
        try:
            body = json.loads(entry.read_text("utf-8"))
            data = base64.b64decode(body["data_base64"]) if body.get("data_base64") else None
            result = PreviewResult(
                data, body.get("mime", ""), Reason(body["reason"]) if body.get("reason") else None,
                body.get("width"), body.get("height"), body.get("duration_seconds"))
            os.utime(entry)
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return result

    def put(self, asset_ref: str, mtime_ns: int, size: int, result: PreviewResult) -> None:
        body = {
            "mime": result.mime, "reason": result.reason.value if result.reason else None,
            "data_base64": base64.b64encode(result.data).decode("ascii") if result.data else None,
            "width": result.width, "height": result.height, "duration_seconds": result.duration_seconds}
        scratch = None
        try:
            self._root.mkdir(parents=True, exist_ok=True)
            fd, scratch = tempfile.mkstemp(dir=self._root, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(body, handle)
            os.replace(scratch, self._entry(asset_ref, mtime_ns, size))
            self._evict()
        except OSError:
            if scratch is not None:
                with contextlib.suppress(OSError):
                    os.unlink(scratch)

    def _evict(self) -> None:
        entries = []
        for path in self._root.glob(f"*{_ENTRY_SUFFIX}"):
            with contextlib.suppress(OSError):
                stat = path.stat()
                entries.append((stat.st_mtime, stat.st_size, path))
        total = sum(size for _, size, _ in entries)
        for _, size, path in sorted(entries):
            if total <= self._max_bytes:
                break
            with contextlib.suppress(OSError):
                path.unlink()
                total -= size
