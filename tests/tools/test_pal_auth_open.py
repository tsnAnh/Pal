from __future__ import annotations

import json

import pytest

from tests.tools.mcp_bearer_server_double import TOOL_NAMES, McpServerDouble

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "open"
SLUG = "palopen"


@pytest.fixture
def mcp():
    with McpServerDouble() as server:
        yield server


def connect(pal, mcp) -> dict:
    pal.add_connector(SLUG, "none", mcp.mcp_url)
    return pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)


def test_an_open_server_connects_with_no_credential_and_answers_tool_calls(mcp, pal):
    pal.add_connector(SLUG, "none", mcp.mcp_url)
    before = pal.connector_row(SLUG)["status"]

    added = pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    probe = pal.rpc("mcp.servers.test", name=SLUG)
    registered = pal.start_agent_tools()
    listing = pal.call(SLUG, "list_projects", limit=3)

    assert before == "not_connected"
    assert added["server"]["auth"] is None and added["server"]["headers"] == []
    assert probe["ok"] is True and {t["name"] for t in probe["tools"]} >= set(TOOL_NAMES)
    assert all(pal.tool(SLUG, name) in registered for name in TOOL_NAMES)
    assert json.loads(listing["result"]) == {"account": "anonymous", "tool": "list_projects", "arguments": {"limit": 3}}
    assert pal.connector_row(SLUG)["status"] == "connected"
    assert not any(sent_bearer for _path, _status, sent_bearer in mcp.traffic.statuses)
    assert mcp.traffic.rejected() == 0


def test_a_write_capable_tool_of_an_open_server_is_called_like_a_read_only_one(mcp, pal):
    connect(pal, mcp)
    pal.start_agent_tools()

    created = pal.call(SLUG, "create_item", title="draft")

    assert json.loads(created["result"])["arguments"] == {"title": "draft"}
    assert [c.account for c in mcp.traffic.calls("create_item")] == ["anonymous"]


def test_the_live_server_is_reported_connected_by_the_status_call(mcp, pal):
    connect(pal, mcp)
    pal.start_agent_tools()

    row = next(r for r in pal.rpc("mcp.servers.status")["servers"] if r["name"] == SLUG)

    assert row["connected"] is True and row["status"] == "connected" and row["needs_auth"] is False
