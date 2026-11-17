"""``connectors.legacy`` lists what a profile connected through the Nous Portal or Composio and has not
connected directly yet, from local files only. Real gateway handlers against a temp ``HERMES_HOME``.
"""

from __future__ import annotations

import json

import pytest
import pytest_asyncio

import hermes_yaml as yaml
from tests.gateway.bots_harness import bots_state, call, failure, install_state
from tui_gateway import server

PROFILE = "work"
SECRET = "sk-legacy-test-not-a-real-token"

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


@pytest.fixture
def work_home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    (root / "profiles" / PROFILE).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root / "profiles" / PROFILE


@pytest.fixture(autouse=True)
def portal_forbidden(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise AssertionError("connectors.legacy reached the Nous Portal")

    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.__init__", refuse)
    monkeypatch.setattr("tools.connectors.portal.client._default_transport", refuse)
    monkeypatch.setattr("tools.connectors.gateway.client.ConnectorClient.__init__", refuse)


def _cache(home, slug, fetched_at):
    path = home / "cache" / "connectors" / "origin0" / "member0" / f"{slug}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"connector": slug, "etag": "e", "toolkit_version": "1", "tools": [],
                                "fetched_at": fetched_at}))


def _servers(home, servers):
    (home / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": servers}))


def _snapshot(home):
    files = [home / "config.yaml", *sorted((home / "cache").rglob("*"))]
    return {str(p): p.read_bytes() for p in files if p.is_file()}


def _legacy():
    response = server._methods["connectors.legacy"](1, {"profile": PROFILE})
    assert "error" not in response, response
    return response["result"]


def test_no_record_says_the_source_could_not_be_read(work_home):
    assert _legacy() == {"source_readable": False, "items": []}


def test_portal_and_composio_records_map_to_catalog_entries_and_unknown_slugs_stay(work_home):
    _cache(work_home, "jira", 1700000000.0)
    _cache(work_home, "asana", 1700000100.0)
    _cache(work_home, "mystery_app", 1700000200.0)
    _servers(work_home, {"notion": {"url": "https://mcp.composio.dev/x/notion", "headers": {"Authorization": SECRET}}})
    _legacy()
    before = _snapshot(work_home)

    result = _legacy()

    items = {item["legacy_slug"]: item for item in result["items"]}
    assert result["source_readable"] is True
    assert items["jira"] == {"catalog_id": "atlassian", "name": "Atlassian", "legacy_slug": "jira",
                             "legacy_source": "portal", "method": "mcp_oauth", "state": "needs_reconnect",
                             "last_seen": 1700000000.0}
    assert items["asana"] == {"catalog_id": None, "name": "Asana", "legacy_slug": "asana",
                              "legacy_source": "portal", "method": None, "state": "unmapped",
                              "last_seen": 1700000100.0}
    assert items["mystery_app"] == {"catalog_id": None, "name": "Mystery App", "legacy_slug": "mystery_app",
                                    "legacy_source": "portal", "method": None, "state": "unmapped",
                                    "last_seen": 1700000200.0}
    assert (items["notion"]["catalog_id"], items["notion"]["legacy_source"]) == ("notion", "composio")
    assert SECRET not in json.dumps(result)
    assert _snapshot(work_home) == before


def test_a_service_connected_directly_drops_out_but_the_source_stays_readable(work_home):
    _cache(work_home, "linear", 1700000000.0)
    _servers(work_home, {"linear": {"url": "https://mcp.linear.app/mcp"}})

    assert _legacy() == {"source_readable": True, "items": []}


@pytest.mark.asyncio
async def test_a_grant_without_read_is_refused(bots):
    response = await call(bots.connect(capabilities=["session:control"]), "connectors.legacy", {})
    assert failure(response)["message"] == "permission_denied"
