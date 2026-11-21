from __future__ import annotations

import json

import pytest

from hermes_cli.config import get_env_value
from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "api-key"
SLUG = "palkey"
KEY = "pal-key-7d41c9e2"
KEY_VARIABLE = "MCP_PALKEY_API_KEY"


@pytest.fixture
def mcp():
    with McpServerDouble(protection=Protection.STATIC_KEY, api_key=KEY) as server:
        yield server


def test_an_api_key_goes_to_the_server_as_a_bearer_header_and_never_into_the_config(mcp, pal):
    pal.add_connector(SLUG, "api_key", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)

    saved = pal.rpc("mcp.servers.set_api_key", name=SLUG, value=KEY)
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert saved.get("ok", True) is not False
    assert json.loads(answer["result"])["account"] == "api-key"
    assert [c.bearer for c in mcp.traffic.calls("whoami")] == [KEY]
    assert get_env_value(KEY_VARIABLE) == KEY
    assert KEY not in (pal.home / "config.yaml").read_text()
    assert "${" + KEY_VARIABLE + "}" in (pal.home / "config.yaml").read_text()
    assert pal.connector_row(SLUG)["status"] == "connected"


def test_a_connector_added_without_its_key_is_not_connected_until_the_key_is_saved(mcp, pal):
    pal.add_connector(SLUG, "api_key", mcp.mcp_url)

    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    without_key = pal.connector_row(SLUG)["status"]
    pal.rpc("mcp.servers.set_api_key", name=SLUG, value=KEY)

    assert without_key == "not_connected"
    assert pal.connector_row(SLUG)["status"] == "connected"
    listed = next(r for r in pal.rpc("mcp.catalog")["servers"] if r["name"] == SLUG)
    assert all(a["status"] == "connected" for a in listed["accounts"])


def test_a_wrong_key_is_refused_by_the_server_and_a_corrected_key_connects(mcp, pal):
    pal.add_connector(SLUG, "api_key", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)

    pal.rpc("mcp.servers.set_api_key", name=SLUG, value="not-the-key")
    refused = pal.rpc("mcp.servers.test", name=SLUG)
    pal.rpc("mcp.servers.set_api_key", name=SLUG, value=KEY)
    accepted = pal.rpc("mcp.servers.test", name=SLUG)

    assert refused["ok"] is False and refused["tools"] == []
    assert "not-the-key" not in json.dumps(refused)
    assert accepted["ok"] is True and {t["name"] for t in accepted["tools"]} >= {"whoami"}
    assert mcp.traffic.rejected() >= 1 and mcp.traffic.tool_calls == []


def test_a_bearer_token_given_when_the_server_is_added_is_sent_the_same_way(mcp, pal):
    added = pal.rpc("mcp.servers.add", name=SLUG,
                    config={"url": mcp.mcp_url, "transport": "http"}, bearer_token=KEY)
    pal.start_agent_tools()
    answer = pal.call(SLUG, "list_projects")

    assert KEY not in json.dumps(added)
    assert json.loads(answer["result"])["account"] == "api-key"
    assert [c.bearer for c in mcp.traffic.calls("list_projects")] == [KEY]
    assert KEY not in (pal.home / "config.yaml").read_text()
