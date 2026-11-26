"""Contracts for ``methods_library``: what a bot's conversations linked to, shared and produced."""

from __future__ import annotations

from enum import StrEnum

from pydantic import Field, model_validator

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class LibraryKindFilter(WireEnum):
    ALL = "all"
    MEDIA = "media"
    LINKS = "links"
    FILES = "files"


class LibraryItemKind(StrEnum):
    LINK = "link"
    MEDIA = "media"
    FILE = "file"


class LibraryListParams(ProfileParams):
    """``limit`` is clamped to 1..200. ``before`` is the ``next_before`` of the previous page."""

    kind: LibraryKindFilter = LibraryKindFilter.ALL
    limit: int = 50
    before: str | None = None


class LibraryItem(Result):
    """``asset_ref`` is set only for a local file ``library.asset`` may serve; ``url`` for a link or a
    remote media item."""

    id: str
    kind: LibraryItemKind
    title: str
    subtitle: str
    url: str | None = None
    asset_ref: str | None = None
    mime: str | None = None
    size: int | None = None
    session_id: str
    occurred_at: str


class LibraryListResult(Result):
    """``index_complete`` is false while a large history is still being indexed: ask again to see more."""

    items: list[LibraryItem]
    next_before: str | None = None
    index_complete: bool = True


method("library.list", params=LibraryListParams, result=LibraryListResult,
       doc="Links, media and files a bot's conversations mention, newest first, deduplicated.")


class LibraryAssetKind(StrEnum):
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    PDF = "pdf"
    DOCUMENT = "document"
    ARCHIVE = "archive"
    OTHER = "other"


class LibraryPreviewReason(StrEnum):
    """Why a preview request returned no image. The app falls back to its own thumbnail or an icon card."""

    NOT_PREVIEWABLE = "not_previewable"
    UNSUPPORTED_KIND = "unsupported_kind"
    TOO_LARGE = "too_large"
    HEIC_DECODER_MISSING = "heic_decoder_missing"
    FFMPEG_MISSING = "ffmpeg_missing"
    PDF_RENDERER_MISSING = "pdf_renderer_missing"
    RENDER_FAILED = "render_failed"
    TIMED_OUT = "timed_out"
    BUSY = "busy"


class AssetReadParams(ProfileParams):
    max_bytes: int | None = None
    thumbnail: bool = True
    preview: bool = False
    offset: int | None = Field(default=None, ge=0)
    length: int | None = Field(default=None, gt=0)

    @model_validator(mode="after")
    def _one_mode(self):
        if self.preview and (self.offset is not None or self.length is not None):
            raise ValueError("preview and offset/length are separate modes")
        return self


class LibraryAssetParams(AssetReadParams):
    """Three call shapes. Whole file (old apps, unchanged): ``max_bytes`` defaults to 8 MB (max 16 MB);
    images come back as a thumbnail of at most 512 px unless ``thumbnail`` is false.
    ``preview`` returns a JPEG or PNG of at most 512 px (video poster frame, first PDF page, still image)
    capped by ``max_bytes``, or an empty ``data_base64`` with ``preview_reason``; sources up to 200 MB for
    video and 32 MB for images and PDF. ``offset`` and/or ``length`` read one range of the file, up to
    2 MB per call, for files up to 200 MB. ``preview`` and ranges do not combine."""

    asset_ref: str


class LibraryAssetResult(Result):
    """``size`` is always the bytes in ``data_base64``; ``total`` is the file's true size.
    ``kind``, ``sniffed_mime`` and ``previewable`` come from the file's first 4 KB, not its name:
    ``previewable`` is false for HTML, SVG, archives, executables, scripts and anything unrecognised.
    ``mime`` stays the name-based type (the preview's own type when a preview image is returned).
    ``offset`` and ``length`` echo the range served; ``length`` can be below the request, and 0 past the end."""

    mime: str
    data_base64: str
    size: int
    total: int | None = None
    kind: LibraryAssetKind | None = None
    sniffed_mime: str | None = None
    previewable: bool | None = None
    preview_reason: LibraryPreviewReason | None = None
    duration_seconds: float | None = None
    width: int | None = None
    height: int | None = None
    offset: int | None = None
    length: int | None = None


method("library.asset", params=LibraryAssetParams, result=LibraryAssetResult,
       doc="Bytes, a preview image or one range of a library media item or file, base64, only for files the "
           "profile's library indexed. Errors: 4151 not found or gone, 4152 larger than the limit (data: size, "
           "limit), 4153 invalid request, 4154 refused by the media-delivery policy, "
           "5151 temporary internal failure.")
