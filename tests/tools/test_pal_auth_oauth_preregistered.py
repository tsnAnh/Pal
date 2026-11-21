from __future__ import annotations

import json
import urllib.request

import pytest

from gateway import oauth_client_setup as setup
from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import OAuthServerDouble
from tests.tools.pal_auth_harness import PUBLIC_URL, Browser, gateway_callback
from tools.connectors.mcp_oauth_redirect import GATEWAY_CALLBACK_PATH
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-preregistered-client"
SLUG = "palprereg"
CLIENT_ID = "owner-registered-client"
CLIENT_SECRET = "owner-client-secret-5e83"
GATEWAY_URI = PUBLIC_URL + GATEWAY_CALLBACK_PATH


@pytest.fixture
def servers():
    with OAuthServerDouble(dcr=False) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def declare(pal, authorization, mcp) -> None:
    pal.add_connector(SLUG, "oauth_client", mcp.mcp_url, oauth_endpoints={
        "authorization_url": f"{authorization.base}/authorize", "token_url": f"{authorization.base}/token"})


def save_client(pal) -> dict:
    ids = [pal.rpc("vault.add", kind="api_key", label=label, secret={"api_key": value})["id"]
           for label, value in (("client id", CLIENT_ID), ("client secret", CLIENT_SECRET))]
    return pal.rpc("connectors.oauth_client.save", slug=SLUG, client_id_item=ids[0], client_secret_item=ids[1])


def test_the_owners_client_signs_in_through_the_gateway_callback_without_registering_dynamically(servers, pal, caplog):
    authorization, mcp = servers
    declare(pal, authorization, mcp)
    pal.set_public_url()
    authorization.preregister(CLIENT_ID, CLIENT_SECRET, [GATEWAY_URI])
    before = pal.connector_row(SLUG)["status"]
    setup_before = pal.rpc("connectors.oauth_client.setup", slug=SLUG)

    saved = save_client(pal)
    ready = pal.connector_row(SLUG)["status"]
    started = pal.rpc("connectors.oauth_client.connect", slug=SLUG)
    landed = Browser().authorize(started["auth_url"])
    page = gateway_callback(landed)
    pal.poll_until(SLUG, started["session_id"])
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert (before, ready) == ("needs_setup", "not_connected")
    assert setup_before["configured"] is False and setup_before["redirect_url"] == GATEWAY_URI
    assert saved["configured"] is True
    assert authorization.registrations == []
    assert authorization.authorize_queries[0]["client_id"] == CLIENT_ID
    assert authorization.authorize_queries[0]["redirect_uri"] == GATEWAY_URI
    assert page.status_code == 200
    exchange = authorization.grant_requests("authorization_code")[0]
    assert exchange["code_verifier"] and exchange["redirect_uri"] == GATEWAY_URI
    assert json.loads(answer["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"
    config_text = (pal.home / "config.yaml").read_text()
    assert CLIENT_SECRET not in config_text + json.dumps([saved, started]) + caplog.text
    assert "${PALPREREG_CLIENT_SECRET}" in config_text


def test_the_owners_client_signs_in_through_a_loopback_receiver_when_the_gateway_has_no_public_address(servers, pal):
    authorization, mcp = servers
    declare(pal, authorization, mcp)
    authorization.preregister(CLIENT_ID, CLIENT_SECRET, [setup.MCP_REDIRECT_URL])
    save_client(pal)

    started = pal.rpc("connectors.oauth_client.connect", slug=SLUG)
    urllib.request.urlopen(started["auth_url"], timeout=10).read()
    pal.poll_until(SLUG, started["session_id"])
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert authorization.registrations == []
    assert authorization.authorize_queries[0]["redirect_uri"] == setup.MCP_REDIRECT_URL
    assert json.loads(answer["result"])["account"] == "owner"


def test_a_client_secret_the_server_does_not_accept_never_signs_in(servers, pal):
    authorization, mcp = servers
    declare(pal, authorization, mcp)
    pal.set_public_url()
    authorization.preregister(CLIENT_ID, "a-different-secret", [GATEWAY_URI])
    save_client(pal)

    started = pal.rpc("connectors.oauth_client.connect", slug=SLUG)
    gateway_callback(Browser().authorize(started["auth_url"]))
    outcome = pal.poll_until(SLUG, started["session_id"], status="error")

    assert outcome["status"] == "error" and CLIENT_SECRET not in json.dumps(outcome)
    assert authorization.grants_by_access == {} and mcp.traffic.tool_calls == []
    assert not any(HermesTokenStorage(name).has_cached_tokens() for name in (SLUG, f"{SLUG}@default"))
