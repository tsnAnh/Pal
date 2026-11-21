from __future__ import annotations

import json

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import GATEWAY, LOOPBACK, OAuthServerDouble
from tests.tools.pal_auth_harness import LOOPBACK_REDIRECT, PUBLIC_URL, Browser, gateway_callback
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI, GATEWAY_CALLBACK_PATH
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-dcr-gateway-https-redirect"
SLUG = "palhttps"
GATEWAY_URI = PUBLIC_URL + GATEWAY_CALLBACK_PATH


@pytest.fixture
def servers():
    with OAuthServerDouble(accepted_redirects=frozenset({GATEWAY, LOOPBACK})) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def begin(pal, mcp) -> dict:
    pal.set_public_url()
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    return pal.rpc("mcp.servers.oauth.start", name=SLUG, client_redirect_uri=APP_REDIRECT_URI,
                   fallback_redirect_uri=LOOPBACK_REDIRECT)


def test_a_server_that_refuses_the_app_redirect_signs_in_through_the_gateway_callback(servers, pal):
    authorization, mcp = servers

    started = begin(pal, mcp)
    landed = Browser().authorize(started["auth_url"])
    page = gateway_callback(landed)
    pal.poll_until(SLUG, started["session_id"])
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert (started["redirect"], started["redirect_uri"]) == ("gateway", GATEWAY_URI)
    assert [r["redirect_uris"] for r in authorization.registrations] == [[APP_REDIRECT_URI], [GATEWAY_URI]]
    assert authorization.authorize_queries[0]["redirect_uri"] == GATEWAY_URI
    assert page.status_code == 200 and "Return to Pal" in page.text
    assert landed["code"] not in page.text and landed["state"] not in page.text
    assert authorization.grant_requests("authorization_code")[0]["redirect_uri"] == GATEWAY_URI
    assert json.loads(answer["result"])["account"] == "owner"


def test_the_gateway_callback_accepts_a_state_once(servers, pal):
    authorization, mcp = servers
    started = begin(pal, mcp)
    landed = Browser().authorize(started["auth_url"])

    first = gateway_callback(landed)
    replay = gateway_callback(landed)
    unknown = gateway_callback({**landed, "state": "never-issued"})

    assert first.status_code == 200
    assert replay.status_code == 400 and unknown.status_code == 400
    assert len(authorization.grant_requests("authorization_code")) == 1


def test_a_denied_sign_in_through_the_gateway_callback_leaves_nothing_behind(servers, pal):
    authorization, mcp = servers
    started = begin(pal, mcp)

    page = gateway_callback({"error": "access_denied", "state": _state_of(started)})
    outcome = pal.poll_until(SLUG, started["session_id"], status="error")

    assert page.status_code == 200 and "not completed" in page.text
    assert outcome["status"] == "error"
    assert not HermesTokenStorage(SLUG + "@default").has_cached_tokens()
    assert authorization.grant_requests("authorization_code") == [] and mcp.traffic.tool_calls == []


def _state_of(started: dict) -> str:
    from urllib.parse import parse_qs, urlsplit

    return parse_qs(urlsplit(started["auth_url"]).query)["state"][0]
