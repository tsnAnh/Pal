"""Contracts for ``methods_library``: what a bot's conversations linked to, shared and produced."""

from __future__ import annotations

from enum import StrEnum

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


class LibraryAssetParams(ProfileParams):
    """``max_bytes`` defaults to 8 MB (max 16 MB). Images come back as a thumbnail of at most 512 px
    unless ``thumbnail`` is false."""

    asset_ref: str
    max_bytes: int | None = None
    thumbnail: bool = True


class LibraryAssetResult(Result):
    mime: str
    data_base64: str
    size: int


method("library.asset", params=LibraryAssetParams, result=LibraryAssetResult,
       doc="Bytes of a library media item or file, base64, only for files the profile's library indexed.")
