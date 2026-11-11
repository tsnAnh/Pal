#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures as cf
import logging
import time
from dataclasses import dataclass, field, replace
from typing import Any, Callable
from urllib.parse import urlsplit, urlunsplit

logger = logging.getLogger(__name__)

EXTRACT_BATCH = 5
NO_PROVIDER_MESSAGE = (
    "deep search needs a web provider; none set. Run `hermes tools` and pick a web search backend."
)
_NO_PROVIDER_MARKERS = ("no web search provider", "no web extract provider")
_TRUNCATED_MARK = "\n[truncated: total output cap reached]"


@dataclass(frozen=True)
class Caps:
    max_queries: int = 6
    results_per_query: int = 5
    max_sources: int = 12
    max_pages: int = 8
    page_chars: int = 4000
    total_chars: int = 24000
    deadline_s: float = 90.0
    workers: int = 4

    def clamped(self) -> Caps:
        return replace(
            self,
            max_queries=max(1, self.max_queries),
            results_per_query=max(1, self.results_per_query),
            max_sources=max(1, self.max_sources),
            max_pages=max(0, self.max_pages),
            page_chars=max(200, self.page_chars),
            total_chars=max(200, self.total_chars),
            deadline_s=max(1.0, self.deadline_s),
            workers=max(1, self.workers),
        )


@dataclass
class Source:
    id: int
    url: str
    title: str
    snippet: str
    found_by: list[str] = field(default_factory=list)
    content: str = ""
    read: bool = False
    read_error: str = ""


@dataclass
class DeepSearchResult:
    status: str
    message: str
    sources: list[Source]
    notes: list[str]
    queries_run: list[str]
    caps: Caps

    def render(self) -> str:
        lines = [f"DEEP SEARCH {self.status.upper()}: {self.message}"]
        if self.notes:
            lines += ["", "Limits and failures:"] + [f"- {note}" for note in self.notes]
        read = [s for s in self.sources if s.read]
        if read:
            lines += ["", "Evidence (cite as [n]):"]
            for s in read:
                lines += ["", f"[{s.id}] {s.title or s.url}", s.content]
        unread = [s for s in self.sources if not s.read]
        if unread:
            lines += ["", "Found but not read (snippet only):"]
            for s in unread:
                reason = f" (not read: {s.read_error})" if s.read_error else ""
                lines.append(f"[{s.id}] {s.title or s.url}: {s.snippet}{reason}")
        if self.sources:
            lines += ["", "Sources:"] + [f"[{s.id}] {s.title or s.url} - {s.url}" for s in self.sources]
        return "\n".join(lines)


def normalize_url(url: str) -> str:
    parts = urlsplit(url.strip())
    path = parts.path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, parts.query, ""))


def _search_rows(response: Any) -> tuple[list[dict], str]:
    if not isinstance(response, dict):
        return [], "search returned no usable response"
    if response.get("error") or response.get("success") is False:
        return [], str(response.get("error") or "search failed")
    rows = ((response.get("data") or {}).get("web")) or []
    return [r for r in rows if isinstance(r, dict) and r.get("url")], ""


def _extract_rows(response: Any) -> tuple[dict[str, tuple[str, str]], str]:
    if not isinstance(response, dict):
        return {}, "extract returned no usable response"
    if response.get("error") and not response.get("results"):
        return {}, str(response["error"])
    by_url: dict[str, tuple[str, str]] = {}
    for entry in response.get("results") or []:
        if isinstance(entry, dict) and entry.get("url"):
            by_url[normalize_url(entry["url"])] = (
                str(entry.get("content") or ""),
                str(entry.get("error") or ""),
            )
    return by_url, ""


def _guarded(fn: Callable[[], Any]) -> tuple[Any, str]:
    try:
        return fn(), ""
    except Exception as exc:
        logger.warning("deep search call failed", exc_info=True)
        return None, f"{type(exc).__name__}: {exc}"


def _run_pool(
    tasks: list[Callable[[], Any]], workers: int, deadline: float
) -> list[tuple[Any, str] | None]:
    results: list[tuple[Any, str] | None] = [None] * len(tasks)
    if not tasks:
        return results
    pool = cf.ThreadPoolExecutor(max_workers=workers)
    futures = {pool.submit(_guarded, task): i for i, task in enumerate(tasks)}
    done, pending = cf.wait(futures, timeout=max(0.0, deadline - time.monotonic()))
    for future in done:
        results[futures[future]] = future.result()
    for future in pending:
        future.cancel()
    pool.shutdown(wait=False, cancel_futures=True)
    return results


def _collect_sources(
    queries: list[str], outcomes: list[tuple[Any, str] | None], caps: Caps, notes: list[str]
) -> list[Source]:
    per_query: list[list[dict]] = []
    unfinished = 0
    for query, outcome in zip(queries, outcomes):
        if outcome is None:
            unfinished += 1
            per_query.append([])
            continue
        rows, error = _search_rows(outcome[0]) if not outcome[1] else ([], outcome[1])
        if error:
            notes.append(f"search failed for {query!r}: {error}")
        per_query.append(rows)
    if unfinished:
        notes.append(f"time cap {caps.deadline_s:g}s reached: {unfinished} search(es) did not finish")

    sources: dict[str, Source] = {}
    overflow = 0
    for rank in range(caps.results_per_query):
        for query, rows in zip(queries, per_query):
            if rank >= len(rows):
                continue
            row = rows[rank]
            key = normalize_url(row["url"])
            if key in sources:
                if query not in sources[key].found_by:
                    sources[key].found_by.append(query)
            elif len(sources) >= caps.max_sources:
                overflow += 1
            else:
                sources[key] = Source(
                    id=len(sources) + 1,
                    url=row["url"].strip(),
                    title=str(row.get("title") or ""),
                    snippet=str(row.get("description") or ""),
                    found_by=[query],
                )
    if overflow:
        notes.append(f"source cap reached: kept {caps.max_sources}, dropped {overflow} more result(s)")
    return list(sources.values())


def _read_pages(
    sources: list[Source], extract: Callable[[list[str]], Any], caps: Caps, deadline: float, notes: list[str]
) -> None:
    targets = sources[: caps.max_pages]
    if len(sources) > len(targets):
        notes.append(f"page cap reached: read {len(targets)} of {len(sources)} sources")
    batches = [targets[i : i + EXTRACT_BATCH] for i in range(0, len(targets), EXTRACT_BATCH)]
    outcomes = _run_pool(
        [(lambda b=b: extract([s.url for s in b])) for b in batches], caps.workers, deadline
    )
    budget = caps.total_chars
    budget_hit = False
    unfinished = 0
    for batch, outcome in zip(batches, outcomes):
        if outcome is None:
            unfinished += len(batch)
            for s in batch:
                s.read_error = "time cap reached"
            continue
        pages, batch_error = _extract_rows(outcome[0]) if not outcome[1] else ({}, outcome[1])
        for s in batch:
            content, page_error = pages.get(normalize_url(s.url), ("", batch_error or "no content returned"))
            if page_error or not content.strip():
                s.read_error = page_error or "empty page"
                continue
            if budget <= 0:
                budget_hit = True
                s.read_error = "total output cap reached"
                continue
            text = content.strip()[: caps.page_chars]
            if len(text) > budget:
                text = text[:budget] + _TRUNCATED_MARK
                budget_hit = True
            budget -= len(text)
            s.content, s.read = text, True
    if unfinished:
        notes.append(f"time cap {caps.deadline_s:g}s reached: {unfinished} page(s) not read")
    if budget_hit:
        notes.append(f"output cap reached: stopped at {caps.total_chars} characters of page text")
    failed = [s for s in targets if not s.read and s.read_error and s.read_error not in (
        "time cap reached", "total output cap reached")]
    for s in failed:
        notes.append(f"could not read {s.url}: {s.read_error}")


def deep_search(
    queries: list[str],
    search: Callable[[str, int], Any],
    extract: Callable[[list[str]], Any],
    caps: Caps | None = None,
) -> DeepSearchResult:
    caps = (caps or Caps()).clamped()
    deadline = time.monotonic() + caps.deadline_s
    notes: list[str] = []
    cleaned = list(dict.fromkeys(q.strip() for q in queries if isinstance(q, str) and q.strip()))
    if not cleaned:
        return DeepSearchResult("failed", "no search queries were given", [], notes, [], caps)
    if len(cleaned) > caps.max_queries:
        notes.append(f"query cap reached: ran {caps.max_queries} of {len(cleaned)} queries")
        cleaned = cleaned[: caps.max_queries]

    outcomes = _run_pool(
        [(lambda q=q: search(q, caps.results_per_query)) for q in cleaned], caps.workers, deadline
    )
    errors = [o[1] or _search_rows(o[0])[1] for o in outcomes if o is not None]
    if errors and len(errors) == len([o for o in outcomes if o is not None]) and all(errors):
        if any(m in e.lower() for e in errors for m in _NO_PROVIDER_MARKERS):
            return DeepSearchResult("failed", NO_PROVIDER_MESSAGE, [], notes, cleaned, caps)

    sources = _collect_sources(cleaned, outcomes, caps, notes)
    if not sources:
        message = "no sources found; every search failed or returned nothing. Try different queries."
        return DeepSearchResult("failed", message, [], notes, cleaned, caps)

    _read_pages(sources, extract, caps, deadline, notes)
    read = sum(1 for s in sources if s.read)
    if read == 0:
        message = f"found {len(sources)} source(s) but could not read any page; snippets only"
        return DeepSearchResult("partial", message, sources, notes, cleaned, caps)
    status = "partial" if notes else "complete"
    message = f"read {read} of {len(sources)} source(s) from {len(cleaned)} queries"
    if notes:
        message += "; the run was cut short, see limits below"
    return DeepSearchResult(status, message, sources, notes, cleaned, caps)
