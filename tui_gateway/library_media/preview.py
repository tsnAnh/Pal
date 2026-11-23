from __future__ import annotations

import logging
from typing import BinaryIO

from tui_gateway.contracts.library import LibraryAssetKind as Kind
from tui_gateway.contracts.library import LibraryPreviewReason as Reason

from . import image, pdf, video
from .result import PreviewResult
from .sniff import Sniffed
from .tools import PreviewStopped, find_tool, preview_slot, tool_input

logger = logging.getLogger(__name__)

PREVIEW_MAX_SIDE = 512
IMAGE_SOURCE_MAX_BYTES = 32_000_000
PDF_SOURCE_MAX_BYTES = 32_000_000
VIDEO_SOURCE_MAX_BYTES = 200_000_000
_STILL_IMAGE_MIMES = frozenset({"image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"})
_HEIF_MIMES = frozenset({"image/heic", "image/heif"})


def _fail(reason: Reason, **metadata) -> PreviewResult:
    return PreviewResult(reason=reason, **metadata)


def _still_image(handle: BinaryIO, size: int, max_bytes: int, *, heif: bool) -> PreviewResult:
    if size > IMAGE_SOURCE_MAX_BYTES:
        return _fail(Reason.TOO_LARGE)
    if heif and not image.heif_available():
        return _fail(Reason.HEIC_DECODER_MISSING)
    with preview_slot():
        thumb = image.thumbnail(handle, PREVIEW_MAX_SIDE)
    if thumb is None:
        return _fail(Reason.RENDER_FAILED)
    if len(thumb.data) > max_bytes:
        return _fail(Reason.TOO_LARGE, width=thumb.width, height=thumb.height)
    return PreviewResult(thumb.data, thumb.mime, width=thumb.width, height=thumb.height)


def _video(handle: BinaryIO, path: str, size: int, max_bytes: int) -> PreviewResult:
    if size > VIDEO_SOURCE_MAX_BYTES:
        return _fail(Reason.TOO_LARGE)
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        return _fail(Reason.FFMPEG_MISSING)
    ffprobe = find_tool("ffprobe")
    source = tool_input(handle, path)
    with preview_slot():
        info = video.probe(ffprobe, source) if ffprobe else None
        metadata = {} if info is None else {
            "width": info.width, "height": info.height, "duration_seconds": info.duration_seconds}
        try:
            data = video.poster(ffmpeg, source, video.poster_offset(info), max_side=PREVIEW_MAX_SIDE, max_bytes=max_bytes)
        except PreviewStopped as stopped:
            return _fail(stopped.reason, **metadata)
    return PreviewResult(data, "image/jpeg", **metadata)


def _pdf(handle: BinaryIO, path: str, size: int, max_bytes: int) -> PreviewResult:
    if size > PDF_SOURCE_MAX_BYTES:
        return _fail(Reason.TOO_LARGE)
    pdftoppm = find_tool("pdftoppm")
    if pdftoppm is None:
        return _fail(Reason.PDF_RENDERER_MISSING)
    with preview_slot():
        data = pdf.first_page(pdftoppm, tool_input(handle, path), max_side=PREVIEW_MAX_SIDE, max_bytes=max_bytes)
    return PreviewResult(data, "image/jpeg")


def render(handle: BinaryIO, path: str, sniffed: Sniffed, size: int, max_bytes: int) -> PreviewResult:
    """``handle`` is the vetted open file, positioned at 0. Never raises for an unrenderable file: the
    result carries the machine reason instead."""
    if not sniffed.previewable:
        return _fail(Reason.NOT_PREVIEWABLE)
    try:
        if sniffed.kind is Kind.IMAGE and sniffed.mime in _STILL_IMAGE_MIMES | _HEIF_MIMES:
            return _still_image(handle, size, max_bytes, heif=sniffed.mime in _HEIF_MIMES)
        if sniffed.kind is Kind.VIDEO:
            return _video(handle, path, size, max_bytes)
        if sniffed.kind is Kind.PDF:
            return _pdf(handle, path, size, max_bytes)
    except PreviewStopped as stopped:
        logger.info("preview not rendered: %s", stopped.reason.value)
        return _fail(stopped.reason)
    return _fail(Reason.UNSUPPORTED_KIND)
