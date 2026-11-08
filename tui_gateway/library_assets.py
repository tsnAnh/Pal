from __future__ import annotations

import base64
import contextlib
import io
import mimetypes
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

from hermes_state_library import IndexedItem

ASSET_REF_RE = re.compile(r"[0-9a-f]{32}")
DEFAULT_MAX_BYTES = 8_000_000
HARD_MAX_BYTES = 16_000_000
THUMBNAIL_SOURCE_MAX_BYTES = 32_000_000
THUMBNAIL_MAX_SIDE = 512

_MEDIA_ROOT_NAMES = (
    "images", "screenshots", "attachments",
    "cache/images", "cache/audio", "cache/videos", "cache/documents", "cache/screenshots",
    "image_cache", "audio_cache", "video_cache", "document_cache", "browser_screenshots",
)
_THUMBNAIL_MIMES = frozenset({"image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"})


class AssetUnavailable(Exception):
    pass


class AssetTooLarge(Exception):
    pass


@dataclass(frozen=True, slots=True)
class AssetPayload:
    mime: str
    data_base64: str
    size: int


def serve_roots(home: Path) -> list[Path]:
    roots = []
    for name in _MEDIA_ROOT_NAMES:
        try:
            roots.append((Path(home) / name).resolve())
        except (OSError, RuntimeError):
            continue
    return roots


def servable_path(home: Path, locator: str) -> Path | None:
    if not os.path.isabs(locator) or locator.lower().startswith(("http://", "https://")):
        return None
    try:
        target = Path(locator).resolve()
        if not any(root in target.parents for root in serve_roots(home)):
            return None
        return target if stat.S_ISREG(target.stat().st_mode) else None
    except (OSError, RuntimeError, ValueError):
        return None


def wire_item(home: Path, item: IndexedItem) -> dict:
    path = servable_path(home, item.locator) if item.kind != "link" else None
    remote = item.locator.lower().startswith(("http://", "https://"))
    size = None
    if path is not None:
        with contextlib.suppress(OSError):
            size = path.stat().st_size
    return {
        "id": item.id,
        "kind": item.kind,
        "title": item.title,
        "subtitle": item.subtitle,
        "url": item.locator if remote else None,
        "asset_ref": item.id if path is not None else None,
        "mime": item.mime,
        "size": size,
        "session_id": item.session_id,
        "occurred_at": item.occurred_at,
    }


def _read_capped(path: Path, cap: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise AssetUnavailable("This item is no longer available.")
        data = handle.read(cap + 1)
    if len(data) > cap:
        raise AssetTooLarge
    return data


def _thumbnail(data: bytes) -> tuple[bytes, str] | None:
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            image.thumbnail((THUMBNAIL_MAX_SIDE, THUMBNAIL_MAX_SIDE))
            has_alpha = image.mode in ("RGBA", "LA") or (image.mode == "P" and "transparency" in image.info)
            out = io.BytesIO()
            if has_alpha:
                image.convert("RGBA").save(out, format="PNG", optimize=True)
                return out.getvalue(), "image/png"
            image.convert("RGB").save(out, format="JPEG", quality=82, optimize=True)
            return out.getvalue(), "image/jpeg"
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        return None


def read_asset(home: Path, item: IndexedItem, *, max_bytes: int, thumbnail: bool) -> AssetPayload:
    path = servable_path(home, item.locator) if item.kind != "link" else None
    if path is None:
        raise AssetUnavailable("This item is not available to download.")
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    wants_thumbnail = thumbnail and mime in _THUMBNAIL_MIMES
    try:
        data = _read_capped(path, THUMBNAIL_SOURCE_MAX_BYTES if wants_thumbnail else max_bytes)
    except OSError as exc:
        raise AssetUnavailable("This item is no longer available.") from exc
    if wants_thumbnail and (thumb := _thumbnail(data)) is not None and len(thumb[0]) <= max_bytes:
        data, mime = thumb
    elif len(data) > max_bytes:
        raise AssetTooLarge
    return AssetPayload(mime, base64.b64encode(data).decode("ascii"), len(data))
