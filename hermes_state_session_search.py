"""Session search shared by the dashboard route and the native ``session.search`` verb.

Id matches run first, then FTS message hits, then title matches fill any remaining slots. Results
are deduped by compression lineage, not raw ``session_id``: auto-compression rotates a chat onto a
fresh id and leaves the old segment in the FTS index. Branches also use ``parent_session_id`` but are
real alternate conversations, so they are NOT collapsed into the parent.
"""

import logging
import re
import time
from typing import Any, Optional

logger = logging.getLogger(__name__)

_MATCH_TOKENS = re.compile(r'"[^"]*"|\S+')
_HIT_FIELDS = ("session_id", "role", "snippet", "timestamp", "source", "model", "session_started")


def is_compression_edge(child: dict, parent: dict) -> bool:
    parent_ended_at = parent.get("ended_at")
    started_at = child.get("started_at")
    return (
        parent.get("end_reason") == "compression"
        and parent_ended_at is not None
        and started_at is not None
        and started_at >= parent_ended_at)


def prefix_match_query(query: str) -> str:
    """Prefix wildcards so partial words match ("nimb" -> "nimb*"); quoted phrases and existing
    wildcards are kept as-is."""
    return " ".join(
        tok if tok.startswith('"') or tok.endswith("*") else tok + "*"
        for tok in _MATCH_TOKENS.findall(query.strip()))


def _hit_payload(row: dict, snippet: str, role, session_started, timestamp=None) -> dict:
    """``last_active`` rides only on id-match rows (sessions table); FTS hits have no row recency and
    leave it null so a client can fall back to ``session_started`` instead of inventing one."""
    return {
        "snippet": snippet, "role": role, "source": row.get("source"),
        "model": row.get("model"), "session_started": session_started,
        "last_active": row.get("last_active"), "timestamp": timestamp}


class SessionSearch:
    def __init__(self, db, query: str, *, limit: int, profile: str, source: Optional[str] = None,
                 sources: Optional[list[str]] = None, exclude_sources: Optional[list[str]] = None,
                 include_hidden: bool = True, visible_hidden_title: Optional[str] = None):
        self.db = db
        self.query = query
        self.limit = limit
        self.profile = profile
        self.source = source or None
        self.sources = sources or None
        self.exclude_sources = exclude_sources or None
        self.include_hidden = include_hidden
        self.visible_hidden_title = visible_hidden_title
        self.now = time.time()
        self.seen: dict[str, dict] = {}
        self._roots: dict[str, str] = {}
        self._tips: dict[str, str] = {}

    @property
    def full(self) -> bool:
        return len(self.seen) >= self.limit

    def run(self) -> list[dict[str, Any]]:
        self._id_lane()
        self._content_lane()
        if not self.full:
            self._title_lane()
        return list(self.seen.values())

    def _session(self, session_id):
        try:
            return self.db.get_session(session_id)
        except Exception:  # health: allow BLE001 -- a chain walk over a half-deleted lineage must degrade to "this id is its own root", never fail the search
            return None

    def _compression_root(self, session_id: str) -> str:
        """Walk parent_session_id to the compression root, memoized per chain; stops at
        branch/delegate edges (those stay searchable)."""
        chain, cur, root = [], session_id, session_id
        while cur and cur not in chain:
            if cur in self._roots:
                root = self._roots[cur]
                break
            chain.append(cur)
            session = self._session(cur)
            parent = session.get("parent_session_id") if isinstance(session, dict) else None
            parent_session = self._session(parent) if parent else None
            if not parent_session or not is_compression_edge(session, parent_session):
                root = cur
                break
            cur = parent
        for node in chain:
            self._roots[node] = root
        return root

    def _lineage_tip(self, session_id: str) -> str:
        """Resolve the tip from the MATCHED id, never from the lineage root: the forward chain walk is
        defensively bounded, so a lineage deeper than the bound truncates to a stale mid id when
        started at the root. Resuming from the matched id is what the CLI does and always reaches the
        live tip (#125041)."""
        if session_id not in self._tips:
            try:
                self._tips[session_id] = self.db.get_compression_tip(session_id) or session_id
            except Exception:  # health: allow BLE001 -- an unresolvable tip falls back to the matched id, which still resumes
                self._tips[session_id] = session_id
        return self._tips[session_id]

    def _enrich(self, sid: str, payload: dict) -> Optional[dict]:
        try:
            row = self.db.get_session_rich_row(sid)
        except Exception:  # health: allow BLE001 -- a hit whose row cannot be hydrated is still a hit, shown by id
            row = None
        if not row:
            return {**payload, "id": sid}
        if row.get("hidden") and not self.include_hidden and row.get("title") != self.visible_hidden_title:
            return None
        last_active = row.get("last_active") or row.get("started_at")
        return {**payload,
                "id": row.get("id") or sid,
                "source": row.get("source"),
                "model": row.get("model"),
                "title": row.get("title"),
                "started_at": row.get("started_at"),
                "ended_at": row.get("ended_at"),
                "last_active": last_active,
                "is_active": row.get("ended_at") is None and (self.now - (last_active or 0)) < 300,
                "message_count": row.get("message_count") or 0,
                "tool_call_count": row.get("tool_call_count") or 0,
                "input_tokens": row.get("input_tokens") or 0,
                "output_tokens": row.get("output_tokens") or 0,
                "preview": row.get("preview"),
                "parent_session_id": row.get("parent_session_id"),
                "archived": bool(row.get("archived"))}

    def _add(self, raw_sid: str, payload: dict) -> None:
        if not raw_sid:
            return
        root = self._compression_root(raw_sid)
        if root in self.seen or self.full:
            return
        sid = self._lineage_tip(raw_sid)
        enriched = self._enrich(sid, {
            **payload, "session_id": sid, "lineage_root": root, "profile": self.profile,
            "is_default_profile": self.profile == "default"})
        if enriched is not None:
            self.seen[root] = enriched

    def _id_lane(self) -> None:
        """Direct ID matches first (pasted ids never appear in message text)."""
        for row in self.db.search_sessions_by_id(
                self.query, limit=self.limit, include_archived=True, source=self.source,
                sources=self.sources, exclude_sources=self.exclude_sources):
            sid = row.get("id")
            preview = (row.get("preview") or "").strip()
            self._add(sid, _hit_payload(row, preview or f"Session ID: {sid}", None, row.get("started_at")))

    def _content_lane(self) -> None:
        include_sources = [self.source] if self.source else self.sources
        # Over-fetch so lineage dedup can still surface `limit` distinct conversations when several
        # hits collapse onto one root.
        matches = self.db.search_messages(
            query=prefix_match_query(self.query), source_filter=include_sources,
            exclude_sources=self.exclude_sources, limit=max(self.limit * 5, 50), fields=_HIT_FIELDS)
        for match in matches:
            if self.full:
                break
            self._add(match["session_id"], _hit_payload(
                match, match.get("snippet", ""), match.get("role"), match.get("session_started"),
                match.get("timestamp")))

    def _title_lane(self) -> None:
        """Title matches fill any remaining slots (#66242): the FTS index only covers message
        content, so a term that lives solely in a manually-set sessions.title would otherwise return
        nothing. The DB layer already LIKE-matches titles across the whole compression chain
        (list_sessions_rich(search_query=), the sidebar listing's helper), so reuse it. Best-effort:
        an old/odd store that rejects the call just skips the lane."""
        try:
            rows = self.db.list_sessions_rich(
                search_query=self.query.strip(), include_archived=True, order_by_last_active=True,
                source=self.source, sources=self.sources, exclude_sources=self.exclude_sources,
                limit=self.limit)
        except Exception:  # health: allow BLE001 -- best-effort supplement lane: an old/odd store that rejects the search_query read must not fail the id+content results already collected
            logger.debug("Title-match supplement skipped for %r", self.query[:200])
            return
        for row in rows:
            if self.full:
                break
            sid = row.get("id")
            if not sid:
                continue
            preview = (row.get("preview") or "").strip()
            self._add(sid, _hit_payload(
                row, preview or f"Session title matched: {self.query.strip()}", None, row.get("started_at")))


def search_sessions(db, query: str, *, limit: int, profile: str, **filters) -> list[dict[str, Any]]:
    """Lineage-deduped session hits for *query* (id, message content, then title); ``limit`` is
    already clamped by the caller."""
    return SessionSearch(db, query, limit=limit, profile=profile, **filters).run()
