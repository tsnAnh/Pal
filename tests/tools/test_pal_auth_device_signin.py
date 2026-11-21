from __future__ import annotations

import asyncio
import json
import time

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import LOOPBACK, OAuthServerDouble
from tests.tools.pal_auth_harness import LOOPBACK_REDIRECT, PUBLIC_URL, agent, hand_over
from tests.waiting import async_wait_until
from tools.auth_required import detect
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI, GATEWAY_CALLBACK_PATH
from tools.mcp_accounts import service_for_server

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-device-signin"
SLUG = "paldevice"
GATEWAY_URI = PUBLIC_URL + GATEWAY_CALLBACK_PATH
SHORT_LIVED = 2
FAST = 5.0


@pytest.fixture
def servers(monkeypatch):
    with OAuthServerDouble(tls=True, accepted_redirects=frozenset({LOOPBACK}), issue_refresh=False) as authorization:
        monkeypatch.setenv("SSL_CERT_FILE", str(authorization.cert_path))
        with McpServerDouble(protection=Protection.OAUTH, authorization_server=authorization) as mcp:
            yield authorization, mcp


def declare(pal, mcp) -> None:
    pal.set_public_url()
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url, sign_in="device")
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)


def silent(authorization, mcp) -> tuple[int, int, int, int]:
    return (len(authorization.registrations), len(authorization.authorize_queries),
            len(authorization.token_requests), len(mcp.traffic.statuses))


@pytest.mark.parametrize("params", [
    {"client_redirect_uri": APP_REDIRECT_URI},
    {"client_redirect_uri": APP_REDIRECT_URI, "fallback_redirect_uri": LOOPBACK_REDIRECT},
    {},
], ids=["app-redirect", "app-redirect-with-fallback", "gateway-default"])
def test_the_gateway_refuses_to_start_a_sign_in_the_owners_device_has_to_run(servers, pal, params):
    authorization, mcp = servers
    declare(pal, mcp)
    before = silent(authorization, mcp)

    refused = pal.rpc_error("mcp.servers.oauth.start", name=SLUG, **params)

    assert refused["code"] == 4034 and refused["data"] == {"reason": "SIGNIN_ON_DEVICE"}
    assert "your own device" in refused["message"]
    assert silent(authorization, mcp) == before == (0, 0, 0, 0)
    assert pal.connector_row(SLUG)["sign_in"] == "device"
    assert pal.connector_row(SLUG)["status"] == "not_connected"


@pytest.mark.asyncio
async def test_the_tokens_the_device_hands_over_serve_tool_calls_and_the_gateway_never_signed_in(servers, pal, phone):
    authorization, mcp = servers
    declare(pal, mcp)

    reply = await hand_over(phone, authorization, f"mcp:{SLUG}")
    await asyncio.to_thread(pal.start_agent_tools)
    answer = await agent(pal, SLUG, "whoami")

    assert reply["result"] == {"ok": True}
    assert json.loads(answer["result"])["account"] == "owner"
    assert [r["redirect_uris"] for r in authorization.registrations] == [[LOOPBACK_REDIRECT]]
    assert len(authorization.grant_requests("authorization_code")) == 1
    assert [q["redirect_uri"] for q in authorization.authorize_queries] == [LOOPBACK_REDIRECT]
    assert pal.connector_row(SLUG)["status"] == "connected"


@pytest.mark.asyncio
async def test_a_handed_over_token_that_ran_out_asks_the_device_again_and_a_new_hand_over_works_at_once(servers, pal, phone):
    authorization, mcp = servers
    declare(pal, mcp)
    await hand_over(phone, authorization, f"mcp:{SLUG}", expires_in=SHORT_LIVED)
    expires_at = time.time() + SHORT_LIVED
    await asyncio.to_thread(pal.start_agent_tools)
    await async_wait_until(lambda: time.time() > expires_at, what="the handed-over token to run out")

    started = time.monotonic()
    answers = [await agent(pal, SLUG, "whoami") for _ in range(3)]

    need = detect(pal.tool(SLUG, "whoami"), {}, json.dumps(answers[0]))
    assert time.monotonic() - started < FAST
    assert need is not None and need.service == service_for_server(f"{SLUG}@default")
    assert all(a["code"] == "reauth_required" for a in answers)
    assert authorization.grant_requests("refresh_token") == [] and mcp.traffic.calls("whoami") == []
    assert pal.connector_row(SLUG)["status"] == "needs_reconnect"

    await hand_over(phone, authorization, f"mcp:{SLUG}")
    recovered = await agent(pal, SLUG, "whoami")

    assert json.loads(recovered["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"
