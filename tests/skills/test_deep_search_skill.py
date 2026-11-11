from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
import threading
from pathlib import Path

import pytest

from plugins.web._common import BaseWebSearchProvider, document, page_error, search_fail, search_ok, web_hit

SKILL_DIR = Path(__file__).resolve().parents[2] / "skills" / "research" / "deep-search"


@pytest.fixture(scope="module")
def ds():
    spec = importlib.util.spec_from_file_location("deep_search_skill", SKILL_DIR / "scripts" / "deep_search.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeWeb(BaseWebSearchProvider):
    NAME = "fake"
    DISPLAY_NAME = "Fake"

    def __init__(self, index: dict[str, list[str]], bodies: dict[str, str]):
        self.index, self.bodies = index, bodies
        self.failing_queries: set[str] = set()
        self.threads: set[int] = set()

    def is_available(self) -> bool:
        return True

    def supports_extract(self) -> bool:
        return True

    def search(self, query: str, limit: int = 5):
        self.threads.add(threading.get_ident())
        if query in self.failing_queries:
            return search_fail("rate limited")
        return search_ok([web_hit(u, f"Title {u}", f"snippet {u}", i + 1) for i, u in enumerate(self.index.get(query, [])[:limit])])

    async def extract(self, urls, **kwargs):
        return [document(u, f"Title {u}", self.bodies[u]) if u in self.bodies else page_error(u, "timed out") for u in urls]


def _install(monkeypatch, provider):
    from agent.web_search_registry import _reset_for_tests, register_provider
    from tools import web_tools

    _reset_for_tests()
    if provider is not None:
        register_provider(provider)
    monkeypatch.setattr(web_tools, "_load_web_config", lambda: {"backend": "fake"} if provider else {})
    monkeypatch.setattr(web_tools, "_ensure_web_plugins_loaded", lambda: None)

    async def _safe(url: str) -> bool:
        return True

    monkeypatch.setattr(web_tools, "async_is_safe_url", _safe)
    return web_tools


def _tool_callables(web_tools):
    search = lambda query, limit: json.loads(web_tools.web_search_tool(query, limit))
    extract = lambda urls: json.loads(asyncio.run(web_tools.web_extract_tool(urls)))
    return search, extract


@pytest.fixture(autouse=True)
def _reset_registry():
    yield
    from agent.web_search_registry import _reset_for_tests

    _reset_for_tests()


def test_multi_source_run_produces_cited_summary_material(ds, monkeypatch):
    urls = {f"q{i}": [f"https://s{i}.example/a", "https://shared.example/x"] for i in range(3)}
    bodies = {u: f"body of {u}" for rows in urls.values() for u in rows}
    provider = FakeWeb(urls, bodies)
    search, extract = _tool_callables(_install(monkeypatch, provider))

    result = ds.deep_search(["q0", "q1", "q2"], search, extract)

    assert result.status == "complete"
    assert [s.url for s in result.sources].count("https://shared.example/x") == 1
    assert len(result.sources) == 4 and all(s.read for s in result.sources)
    shared = next(s for s in result.sources if "shared" in s.url)
    assert shared.found_by == ["q0", "q1", "q2"]
    text = result.render()
    for s in result.sources:
        assert f"[{s.id}]" in text and s.content in text and f"- {s.url}" in text
    assert text.index("Evidence") < text.index("Sources:")
    assert len(provider.threads) >= 1


def test_unconfigured_provider_says_so_plainly(ds, monkeypatch):
    from tools import web_tools

    web_tools_ = _install(monkeypatch, None)
    monkeypatch.setattr(web_tools_, "_ddgs_package_importable", lambda: False)
    monkeypatch.setattr(web_tools_, "_keyless_backend", lambda: None)
    for var in ("TAVILY_API_KEY", "PERPLEXITY_API_KEY", "EXA_API_KEY", "PARALLEL_API_KEY", "KEENABLE_API_KEY",
                "FIRECRAWL_API_KEY", "FIRECRAWL_API_URL", "BRAVE_SEARCH_API_KEY", "SEARXNG_URL"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(web_tools_, "_is_tool_gateway_ready", lambda: False)
    monkeypatch.setattr(web_tools_, "_managed_web_search", lambda: False)
    search, extract = _tool_callables(web_tools_)

    result = ds.deep_search(["anything"], search, extract)

    assert result.status == "failed"
    assert result.message == ds.NO_PROVIDER_MESSAGE
    assert "deep search needs a web provider; none set" in result.render()


def test_provider_errors_give_partial_result_with_reasons(ds, monkeypatch):
    index = {"good": ["https://ok.example/1", "https://dead.example/2"], "bad": ["https://never.example/3"]}
    provider = FakeWeb(index, {"https://ok.example/1": "ok body"})
    provider.failing_queries = {"bad"}
    search, extract = _tool_callables(_install(monkeypatch, provider))

    result = ds.deep_search(["good", "bad"], search, extract)

    assert result.status == "partial"
    notes = "\n".join(result.notes)
    assert "search failed for 'bad': rate limited" in notes
    assert "could not read https://dead.example/2: timed out" in notes
    text = result.render()
    assert "ok body" in text and "Found but not read" in text and "https://dead.example/2" in text


def test_every_search_failing_is_an_explicit_failure_not_empty(ds, monkeypatch):
    provider = FakeWeb({}, {})
    provider.failing_queries = {"a", "b"}
    search, extract = _tool_callables(_install(monkeypatch, provider))

    result = ds.deep_search(["a", "b"], search, extract)

    assert result.status == "failed"
    assert "no sources found" in result.message
    assert "rate limited" in result.render()


def test_no_queries_is_an_explicit_failure(ds):
    result = ds.deep_search(["  ", ""], lambda q, n: {}, lambda urls: {})
    assert result.status == "failed" and "no search queries" in result.render()


def _rows(prefix: str, n: int) -> dict:
    return {"data": {"web": [{"url": f"https://{prefix}{i}.example/p", "title": f"T{i}", "description": "d"} for i in range(n)]}}


def _pages(urls: list[str], size: int) -> dict:
    return {"results": [{"url": u, "title": u, "content": "x" * size} for u in urls]}


def test_query_cap(ds):
    ran: list[str] = []

    def search(q, n):
        ran.append(q)
        return _rows(q, 1)

    result = ds.deep_search([f"q{i}" for i in range(9)], search, lambda urls: _pages(urls, 10), ds.Caps(max_queries=3))

    assert sorted(ran) == ["q0", "q1", "q2"]
    assert result.status == "partial"
    assert "query cap reached: ran 3 of 9 queries" in result.notes[0]


def test_source_and_page_caps(ds):
    asked: list[str] = []

    def extract(urls):
        asked.extend(urls)
        return _pages(urls, 50)

    result = ds.deep_search(
        ["a", "b"], lambda q, n: _rows(q, 5), extract, ds.Caps(max_sources=6, max_pages=3, results_per_query=5)
    )

    assert len(result.sources) == 6
    assert len(asked) == 3
    assert sum(s.read for s in result.sources) == 3
    notes = "\n".join(result.notes)
    assert "source cap reached: kept 6, dropped 4" in notes
    assert "page cap reached: read 3 of 6 sources" in notes
    assert result.status == "partial"


def test_page_and_total_output_caps(ds):
    result = ds.deep_search(
        ["a"], lambda q, n: _rows(q, 4), lambda urls: _pages(urls, 5000),
        ds.Caps(page_chars=1000, total_chars=2500, max_pages=4),
    )

    assert all(len(s.content) <= 1000 + len(ds._TRUNCATED_MARK) for s in result.sources if s.read)
    assert sum(len(s.content) for s in result.sources) <= 2500 + len(ds._TRUNCATED_MARK)
    assert sum(s.read for s in result.sources) == 3
    assert any("total output cap reached" == s.read_error for s in result.sources)
    assert "output cap reached: stopped at 2500 characters" in "\n".join(result.notes)
    assert result.status == "partial"


def test_time_cap_returns_what_finished(ds):
    release = threading.Event()

    def search(q, n):
        if q == "slow":
            release.wait(timeout=30)
        return _rows(q, 1)

    try:
        result = ds.deep_search(["fast", "slow"], search, lambda urls: _pages(urls, 20), ds.Caps(deadline_s=1.0))
    finally:
        release.set()

    assert result.status == "partial"
    assert "time cap 1s reached: 1 search(es) did not finish" in "\n".join(result.notes)
    assert [s.url for s in result.sources] == ["https://fast0.example/p"]
    assert result.sources[0].read
