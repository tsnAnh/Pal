from __future__ import annotations

from .base import Result
from .common import ProfileParams
from .registry import canonical_method


class SessionSearchParams(ProfileParams):
    """``query`` is trimmed and must be 1..200 characters. ``limit`` defaults to 20 and is clamped to 1..50."""

    query: str
    limit: int = 20


class SessionSearchHit(Result):
    """``session_id`` is the conversation's lineage root and ``resolved_id`` the compression-lineage tip
    ``session.list`` reports. ``role`` and ``timestamp`` are null for a hit on a session id or title.
    ``snippet`` is plain text of at most 240 characters; ``timestamp`` is the matching message's unix seconds."""

    session_id: str
    resolved_id: str | None = None
    title: str | None
    snippet: str
    role: str | None
    timestamp: float | None
    profile: str


class SessionSearchResult(Result):
    results: list[SessionSearchHit]


canonical_method("session.search", params=SessionSearchParams, result=SessionSearchResult,
                 doc="Search a profile's visible conversations by session id, message text and title: id "
                     "matches first, then message hits, then title matches, one hit per conversation. "
                     "Hidden and internal sessions never match.")
