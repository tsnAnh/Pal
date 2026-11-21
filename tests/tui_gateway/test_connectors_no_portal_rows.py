"""A profile that once connected through the Nous Portal gets no portal rows in the Pal connector RPCs.

Real gateway handlers against a temp ``HERMES_HOME`` holding a populated portal cache.
"""

from __future__ import annotations

import json

import pytest

from tui_gateway import server

PORTAL_SLUGS = ("jira", "asana", "mystery_app")


def call(method: str, params: dict | None = None) -> dict:
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def seed_portal_cache(home) -> None:
    cache = home / "cache" / "connectors" / "origin0" / "member0"
    cache.mkdir(parents=True)
    for slug in PORTAL_SLUGS:
        (cache / f"{slug}.json").write_text(json.dumps(
            {"connector": slug, "etag": "e", "toolkit_version": "1", "tools": [], "fetched_at": 1700000000.0}))


@pytest.fixture
def work_home(tmp_path, monkeypatch):
    home = tmp_path / "hermes_home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    return home


def test_the_catalog_is_the_same_with_and_without_a_populated_portal_cache(work_home):
    before = call("connectors.catalog")["result"]["connectors"]
    seed_portal_cache(work_home)

    after = call("connectors.catalog")["result"]["connectors"]

    assert after == before
    assert not {"mystery_app"} & {row["slug"] for row in after}


def test_the_legacy_listing_is_gone_so_no_portal_row_can_be_returned(work_home):
    seed_portal_cache(work_home)

    response = call("connectors.legacy")

    assert response["error"]["code"] == -32601
    assert "result" not in response
