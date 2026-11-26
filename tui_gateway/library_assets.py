from __future__ import annotations

import base64
import contextlib
import mimetypes
import os
import re
import stat
from collections.abc import Iterator
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import BinaryIO

from hermes_state_library import IndexedItem
from tui_gateway.contracts.library import LibraryPreviewReason
from tui_gateway.library_media import (
    HEAD_BYTES,
    IMAGE_SOURCE_MAX_BYTES,
    PREVIEW_MAX_SIDE,
    PreviewCache,
    PreviewResult,
    Sniffed,
    render,
    sniff,
)
from tui_gateway.library_media import thumbnail as make_thumbnail

ASSET_REF_RE = re.compile(r"[0-9a-f]{32}")
DEFAULT_MAX_BYTES = 8_000_000
HARD_MAX_BYTES = 16_000_000
THUMBNAIL_SOURCE_MAX_BYTES = IMAGE_SOURCE_MAX_BYTES
THUMBNAIL_MAX_SIDE = PREVIEW_MAX_SIDE
DOWNLOAD_MAX_BYTES = 200_000_000
CHUNK_MAX_BYTES = 2_000_000
PREVIEW_CACHE_DIR = "cache/library-previews"

_MEDIA_ROOT_NAMES = (
    "images", "screenshots", "attachments",
    "cache/images", "cache/audio", "cache/videos", "cache/documents", "cache/screenshots",
    "image_cache", "audio_cache", "video_cache", "document_cache", "browser_screenshots",
)
_THUMBNAIL_MIMES = frozenset({"image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"})


class AssetUnavailable(Exception):
    pass


class AssetNotAllowed(Exception):
    pass


class AssetTooLarge(Exception):
    def __init__(self, size: int | None, limit: int):
        super().__init__(size, limit)
        self.size = size
        self.limit = limit


@dataclass(frozen=True, slots=True)
class AssetPayload:
    mime: str
    data_base64: str
    size: int
    total: int
    sniffed: Sniffed
    preview_reason: LibraryPreviewReason | None = None
    duration_seconds: float | None = None
    width: int | None = None
    height: int | None = None
    offset: int | None = None
    length: int | None = None

    def wire(self) -> dict:
        fields = {
            "mime": self.mime, "data_base64": self.data_base64, "size": self.size, "total": self.total,
            "kind": self.sniffed.kind.value, "sniffed_mime": self.sniffed.mime,
            "previewable": self.sniffed.previewable,
            "preview_reason": self.preview_reason.value if self.preview_reason else None,
            "duration_seconds": self.duration_seconds, "width": self.width, "height": self.height,
            "offset": self.offset, "length": self.length,
        }
        return {key: value for key, value in fields.items() if value is not None}


@dataclass(frozen=True, slots=True)
class OpenedAsset:
    path: Path
    handle: BinaryIO
    status: os.stat_result


def serve_roots(home: Path) -> list[Path]:
    roots = []
    for name in _MEDIA_ROOT_NAMES:
        try:
            roots.append((Path(home) / name).resolve())
        except (OSError, RuntimeError):
            continue
    return roots


def _delivered_path(locator: str) -> Path | None:
    from gateway.platforms.base import validate_media_delivery_path
    safe = validate_media_delivery_path(locator)
    return Path(safe) if safe else None


def resolve_servable(home: Path, locator: str, *, assistant_produced: bool = False) -> Path:
    if not os.path.isabs(locator) or locator.lower().startswith(("http://", "https://")):
        raise AssetUnavailable("This item is not available to download.")
    try:
        target = Path(locator).resolve()
        if not any(root in target.parents for root in serve_roots(home)):
            delivered = _delivered_path(locator) if assistant_produced else None
            if delivered is None:
                if stat.S_ISREG(target.stat().st_mode):
                    raise AssetNotAllowed("The bot's file-sharing policy does not allow this file.")
                raise AssetUnavailable("This item is no longer available.")
            target = delivered
        if not stat.S_ISREG(target.stat().st_mode):
            raise AssetUnavailable("This item is no longer available.")
        return target
    except (OSError, RuntimeError, ValueError) as exc:
        raise AssetUnavailable("This item is no longer available.") from exc


def servable_path(home: Path, locator: str, *, assistant_produced: bool = False) -> Path | None:
    try:
        return resolve_servable(home, locator, assistant_produced=assistant_produced)
    except (AssetUnavailable, AssetNotAllowed):
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


def _guess_mime(path: Path) -> str:
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"


@contextlib.contextmanager
def _open_regular(path: Path) -> Iterator[tuple[BinaryIO, os.stat_result]]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise AssetUnavailable("This item is no longer available.") from exc
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise AssetUnavailable("This item is no longer available.")
        handle = os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise
    with handle:
        yield handle, status


def _read_capped(handle: BinaryIO, size: int, cap: int) -> bytes:
    data = handle.read(cap + 1)
    if len(data) > cap:
        raise AssetTooLarge(size, cap)
    return data


def asset_payload(opened: OpenedAsset, *, max_bytes: int, thumbnail: bool) -> AssetPayload:
    mime = _guess_mime(opened.path)
    wants_thumbnail = thumbnail and mime in _THUMBNAIL_MIMES
    total = opened.status.st_size
    data = _read_capped(opened.handle, total, THUMBNAIL_SOURCE_MAX_BYTES if wants_thumbnail else max_bytes)
    sniffed = sniff(data[:HEAD_BYTES], opened.path.name)
    if wants_thumbnail and (thumb := make_thumbnail(BytesIO(data), THUMBNAIL_MAX_SIDE)) is not None and len(thumb.data) <= max_bytes:
        data, mime = thumb.data, thumb.mime
    elif len(data) > max_bytes:
        raise AssetTooLarge(len(data), max_bytes)
    return AssetPayload(mime, base64.b64encode(data).decode("ascii"), len(data), total, sniffed)


def chunk_payload(opened: OpenedAsset, *, offset: int, length: int | None) -> AssetPayload:
    total = opened.status.st_size
    if total > DOWNLOAD_MAX_BYTES:
        raise AssetTooLarge(total, DOWNLOAD_MAX_BYTES)
    sniffed = sniff(opened.handle.read(HEAD_BYTES), opened.path.name)
    want = min(length or CHUNK_MAX_BYTES, CHUNK_MAX_BYTES, max(total - offset, 0))
    data = b""
    if want:
        opened.handle.seek(offset)
        data = opened.handle.read(want)
    return AssetPayload(
        _guess_mime(opened.path), base64.b64encode(data).decode("ascii"), len(data), total, sniffed,
        offset=offset, length=len(data))


def preview_payload(home: Path, cache_key: str, opened: OpenedAsset, *, max_bytes: int) -> AssetPayload:
    cache = PreviewCache(home / PREVIEW_CACHE_DIR)
    status = opened.status
    sniffed = sniff(opened.handle.read(HEAD_BYTES), opened.path.name)
    opened.handle.seek(0)
    result = cache.get(cache_key, status.st_mtime_ns, status.st_size)
    if result is None:
        result = render(opened.handle, str(opened.path), sniffed, status.st_size, max_bytes)
        if result.cacheable:
            cache.put(cache_key, status.st_mtime_ns, status.st_size, result)
    return _rendered_payload(opened.path, status.st_size, sniffed, result, max_bytes)


@contextlib.contextmanager
def _open_item(home: Path, item: IndexedItem, assistant_produced: bool) -> Iterator[OpenedAsset]:
    if item.kind == "link":
        raise AssetUnavailable("This item is not available to download.")
    path = resolve_servable(home, item.locator, assistant_produced=assistant_produced)
    try:
        with _open_regular(path) as (handle, status):
            yield OpenedAsset(path, handle, status)
    except OSError as exc:
        raise AssetUnavailable("This item is no longer available.") from exc


def read_asset(
    home: Path, item: IndexedItem, *, max_bytes: int, thumbnail: bool, assistant_produced: bool = False,
) -> AssetPayload:
    with _open_item(home, item, assistant_produced) as opened:
        return asset_payload(opened, max_bytes=max_bytes, thumbnail=thumbnail)


def read_chunk(
    home: Path, item: IndexedItem, *, offset: int, length: int | None, assistant_produced: bool = False,
) -> AssetPayload:
    with _open_item(home, item, assistant_produced) as opened:
        return chunk_payload(opened, offset=offset, length=length)


def read_preview(
    home: Path, item: IndexedItem, *, max_bytes: int, assistant_produced: bool = False,
) -> AssetPayload:
    with _open_item(home, item, assistant_produced) as opened:
        return preview_payload(home, item.id, opened, max_bytes=max_bytes)


def _rendered_payload(path: Path, total: int, sniffed: Sniffed, result: PreviewResult, max_bytes: int) -> AssetPayload:
    reason = result.reason
    data = result.data
    if data is not None and len(data) > max_bytes:
        data, reason = None, LibraryPreviewReason.TOO_LARGE
    return AssetPayload(
        result.mime if data else _guess_mime(path), base64.b64encode(data or b"").decode("ascii"),
        len(data or b""), total, sniffed, reason, result.duration_seconds, result.width, result.height)
