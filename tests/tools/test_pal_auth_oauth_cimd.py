from __future__ import annotations

import json

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import GATEWAY, OAuthServerDouble
from tests.tools.pal_auth_harness import (
    LOOPBACK_REDIRECT, PUBLIC_URL, Browser, gateway_callback, gateway_document_fetcher)
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI, CLIENT_METADATA_PATH, GATEWAY_CALLBACK_PATH
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-cimd-gateway-document"
SLUG = "palcimd"
DOCUMENT_URL = PUBLIC_URL + CLIENT_METADATA_PATH
GATEWAY_URI = PUBLIC_URL + GATEWAY_CALLBACK_PATH
NEEDS_PUBLIC_URL = 4412


@pytest.fixture
def servers():
    with OAuthServerDouble(dcr=False, cimd=True, accepted_redirects=frozenset({GATEWAY}),
                           document_fetcher=gateway_document_fetcher()) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def declare(pal, mcp) -> None:
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url, cimd=True)


def silent(authorization, mcp) -> tuple[int, int, int, int, int]:
    return (len(authorization.registrations), len(authorization.authorize_queries), len(authorization.token_requests),
            len(authorization.log.cimd_fetches), len(mcp.traffic.statuses))


def start(pal) -> dict:
    return pal.rpc("mcp.servers.oauth.start", name=SLUG, client_redirect_uri=APP_REDIRECT_URI,
                   fallback_redirect_uri=LOOPBACK_REDIRECT)


def test_without_a_public_address_the_sign_in_is_unavailable_and_the_vendor_is_never_contacted(servers, pal):
    authorization, mcp = servers
    declare(pal, mcp)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    before = silent(authorization, mcp)

    refused = pal.rpc_error("mcp.servers.oauth.start", name=SLUG, client_redirect_uri=APP_REDIRECT_URI,
                            fallback_redirect_uri=LOOPBACK_REDIRECT)

    assert refused["code"] == NEEDS_PUBLIC_URL and refused["data"] == {"reason": "NEEDS_PUBLIC_URL"}
    assert "public web address" in refused["message"]
    assert silent(authorization, mcp) == before
    assert authorization.registrations == [] and authorization.log.cimd_fetches == []
    assert not HermesTokenStorage(SLUG).has_cached_tokens()


def test_the_connector_is_unavailable_until_the_gateway_has_an_https_public_address(servers, pal):
    authorization, mcp = servers
    declare(pal, mcp)

    before = pal.connector_row(SLUG)["status"]
    pal.set_public_url()
    after = pal.connector_row(SLUG)["status"]

    assert (before, after) == ("needs_setup", "not_connected")
    assert silent(authorization, mcp) == (0, 0, 0, 0, 0)


def test_the_vendor_fetches_the_document_from_the_owners_gateway_and_returns_to_its_callback(servers, pal):
    authorization, mcp = servers
    pal.set_public_url()
    declare(pal, mcp)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)

    started = start(pal)
    landed = Browser().authorize(started["auth_url"])
    page = gateway_callback(landed)
    pal.poll_until(SLUG, started["session_id"])
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert (started["redirect"], started["redirect_uri"]) == ("gateway", GATEWAY_URI)
    assert authorization.log.cimd_fetches == [DOCUMENT_URL]
    assert authorization.registrations == []
    assert authorization.authorize_queries[0]["client_id"] == DOCUMENT_URL
    assert authorization.authorize_queries[0]["redirect_uri"] == GATEWAY_URI
    assert page.status_code == 200
    exchange = authorization.grant_requests("authorization_code")[0]
    assert exchange["client_id"] == DOCUMENT_URL and exchange["redirect_uri"] == GATEWAY_URI
    assert json.loads(answer["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"
