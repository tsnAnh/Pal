from __future__ import annotations

import asyncio
import json
import logging
import time

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import OAuthServerDouble
from tests.tools.pal_auth_harness import agent, hand_over
from tests.waiting import async_wait_until

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "device-handover"
SLUG = "palhand"


@pytest.fixture
def servers(monkeypatch):
    with OAuthServerDouble(tls=True) as authorization:
        monkeypatch.setenv("SSL_CERT_FILE", str(authorization.cert_path))
        with McpServerDouble(protection=Protection.OAUTH, authorization_server=authorization) as mcp:
            yield authorization, mcp


@pytest.mark.asyncio
async def test_tokens_the_device_obtained_with_a_loopback_redirect_serve_tool_calls(servers, pal, phone, caplog):
    authorization, mcp = servers
    caplog.set_level(logging.DEBUG)
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url, signin_on="owner_app")

    reply = await hand_over(phone, authorization, f"mcp:{SLUG}")
    await asyncio.to_thread(pal.start_agent_tools)
    answer = await agent(pal, SLUG, "whoami")

    issued = authorization.tokens_of("owner")[0]
    assert reply["result"] == {"ok": True}
    assert json.loads(answer["result"])["account"] == "owner"
    assert mcp.traffic.calls("whoami")[0].bearer == issued.access_token
    assert len(authorization.grant_requests("authorization_code")) == 1
    assert authorization.registrations[0]["redirect_uris"] == ["http://127.0.0.1:53682/callback"]
    assert issued.access_token not in caplog.text + json.dumps(reply) + (pal.home / "config.yaml").read_text()
    assert pal.connector_row(SLUG)["status"] == "connected"


@pytest.mark.asyncio
async def test_the_gateway_refreshes_a_handed_over_token_by_itself_when_it_expires(servers, pal, phone):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url, signin_on="owner_app")
    await hand_over(phone, authorization, f"mcp:{SLUG}", expires_in=2)
    expires_at = time.time() + 2
    await asyncio.to_thread(pal.start_agent_tools)
    first_token = authorization.tokens_of("owner")[0].access_token

    await async_wait_until(lambda: time.time() > expires_at, what="the handed-over token to expire")
    answer = await agent(pal, SLUG, "whoami")

    refreshes = authorization.grant_requests("refresh_token")
    assert json.loads(answer["result"])["account"] == "owner"
    assert len(refreshes) == 1
    assert mcp.traffic.calls("whoami")[0].bearer != first_token


@pytest.mark.asyncio
async def test_a_hand_over_for_a_named_account_lands_under_it_and_calls_route_by_alias(servers, pal, phone):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url, signin_on="owner_app")

    replies = [await hand_over(phone, authorization, f"mcp:{SLUG}:{alias}", account=alias) for alias in ("default", "work")]
    await asyncio.to_thread(pal.start_agent_tools)
    work = await agent(pal, SLUG, "whoami", connector_alias="work")
    personal = await agent(pal, SLUG, "whoami", connector_alias="default")

    assert [r["result"] for r in replies] == [{"ok": True}, {"ok": True}]
    assert list(pal.read_config()["mcp_servers"][SLUG]["accounts"]) == ["default", "work"]
    assert json.loads(work["result"])["account"] == "work" and json.loads(personal["result"])["account"] == "default"
    assert all("connector_alias" not in call.arguments for call in mcp.traffic.calls("whoami"))
