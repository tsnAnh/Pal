from __future__ import annotations

import asyncio
import json

import pytest

from plugins.web._common import BaseWebSearchProvider, document, page_error, search_fail, search_ok, web_hit

PAGES = {
    "https://alpha.example/guide": "Alpha guide body: the fix is to rotate the lock file.",
    "https://beta.example/notes": "Beta notes body: rotation takes two minutes.",
}


class FakeWebProvider(BaseWebSearchProvider):
    NAME = "fake"
    DISPLAY_NAME = "Fake"

    def __init__(self):
        self.searches: list[tuple[str, int]] = []
        self.extracts: list[list[str]] = []
        self.search_error: str | None = None

    def is_available(self) -> bool:
        return True

    def supports_extract(self) -> bool:
        return True

    def search(self, query: str, limit: int = 5):
        self.searches.append((query, limit))
        if self.search_error:
            return search_fail(self.search_error)
        return search_ok([
            web_hit("https://alpha.example/guide", "Alpha guide", "how to fix", 1),
            web_hit("https://beta.example/notes", "Beta notes", "quick notes", 2),
        ][:limit])

    async def extract(self, urls, **kwargs):
        self.extracts.append(list(urls))
        return [
            document(u, u.split("/")[-1], PAGES[u]) if u in PAGES else page_error(u, "404 not found")
            for u in urls
        ]


@pytest.fixture
def fake_web(monkeypatch):
    from agent.web_search_registry import _reset_for_tests, register_provider
    from tools import web_tools

    provider = FakeWebProvider()
    _reset_for_tests()
    register_provider(provider)
    monkeypatch.setattr(web_tools, "_load_web_config", lambda: {"backend": "fake"})
    monkeypatch.setattr(web_tools, "_ensure_web_plugins_loaded", lambda: None)

    async def _public_only(url: str) -> bool:
        return "internal.local" not in url

    monkeypatch.setattr(web_tools, "async_is_safe_url", _public_only)
    yield provider
    _reset_for_tests()


def test_search_then_read_each_result_page(fake_web):
    from tools import web_tools

    search = json.loads(web_tools.web_search_tool("rotate lock file", limit=5))
    assert search["success"] is True
    urls = [row["url"] for row in search["data"]["web"]]
    assert urls == list(PAGES)

    extracted = json.loads(asyncio.run(web_tools.web_extract_tool(urls)))
    by_url = {r["url"]: r for r in extracted["results"]}
    assert set(by_url) == set(PAGES)
    for url, body in PAGES.items():
        assert body in by_url[url]["content"]
    assert fake_web.searches and fake_web.extracts == [urls]


def test_extract_reports_per_page_failure_and_blocks_private_hosts(fake_web):
    from tools import web_tools

    urls = ["https://alpha.example/guide", "https://missing.example/x", "http://internal.local/admin"]
    results = json.loads(asyncio.run(web_tools.web_extract_tool(urls)))["results"]
    by_url = {r["url"]: r for r in results}
    assert PAGES["https://alpha.example/guide"] in by_url[urls[0]]["content"]
    assert "404" in by_url[urls[1]]["error"]
    assert "private or internal" in by_url[urls[2]]["error"]
    assert fake_web.extracts == [urls[:2]]


def test_provider_search_error_is_returned_not_swallowed(fake_web):
    from tools import web_tools

    fake_web.search_error = "quota exceeded"
    response = json.loads(web_tools.web_search_tool("anything"))
    assert response["success"] is False
    assert "quota exceeded" in response["error"]
