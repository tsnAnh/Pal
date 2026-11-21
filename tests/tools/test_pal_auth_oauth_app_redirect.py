from __future__ import annotations

import json
import time

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import APP, OAuthServerDouble
from tests.tools.pal_auth_harness import Browser
from tests.waiting import wait_until
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-dcr-app-redirect"
SLUG = "paloauth"


@pytest.fixture
def servers():
    with OAuthServerDouble(accepted_redirects=frozenset({APP}), expires_in=3) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def test_the_device_completes_the_browser_step_and_the_agent_calls_a_tool_as_the_signed_in_account(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    before = pal.connector_row(SLUG)["status"]
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)

    started = pal.sign_in_with_app_redirect(SLUG)
    pal.start_agent_tools()
    answer = pal.call(SLUG, "whoami")

    assert before == "not_connected"
    assert started["redirect"] == "app" and started["redirect_uri"] == APP_REDIRECT_URI
    assert [r["redirect_uris"] for r in authorization.registrations] == [[APP_REDIRECT_URI]]
    query = authorization.authorize_queries[0]
    assert query["code_challenge_method"] == "S256" and query["resource"] == mcp.mcp_url
    code_grant = authorization.grant_requests("authorization_code")[0]
    assert code_grant["redirect_uri"] == APP_REDIRECT_URI and code_grant["code_verifier"]
    assert json.loads(answer["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"


def test_a_connector_added_but_not_signed_in_is_not_connected_anywhere(servers, pal):
    _, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)

    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    pal.start_agent_tools()

    listed = next(r for r in pal.rpc("mcp.catalog")["servers"] if r["name"] == SLUG)
    row = next(r for r in pal.rpc("mcp.servers.status")["servers"] if r["name"] == SLUG)
    assert pal.connector_row(SLUG)["status"] == "not_connected"
    assert all(a["status"] == "not_connected" for a in listed["accounts"])
    assert row["connected"] is False
    assert not HermesTokenStorage(SLUG).has_cached_tokens()


def test_a_code_returned_with_a_foreign_state_is_refused_and_the_sign_in_still_finishes_with_the_right_one(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    started = pal.rpc("mcp.servers.oauth.start", name=SLUG, client_redirect_uri=APP_REDIRECT_URI)
    landed = Browser().authorize(started["auth_url"])
    scope = {"name": SLUG, "session_id": started["session_id"]}

    refused = pal.rpc("mcp.servers.oauth.callback", **scope, code=landed["code"], state="a-state-from-another-sign-in")
    waiting = pal.rpc("mcp.servers.oauth.poll", **scope)

    assert refused["ok"] is False and waiting["status"] == "pending"
    assert not HermesTokenStorage(SLUG + "@default").has_cached_tokens() and authorization.grant_requests("authorization_code") == []

    accepted = pal.rpc("mcp.servers.oauth.callback", **scope, code=landed["code"], state=landed["state"], iss=landed["iss"])
    pal.poll_until(SLUG, started["session_id"])

    assert accepted["ok"] is True and len(authorization.grant_requests("authorization_code")) == 1


def test_the_gateway_refreshes_an_expired_access_token_by_itself(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    pal.sign_in_with_app_redirect(SLUG)
    pal.start_agent_tools()
    first = pal.call(SLUG, "whoami")
    first_token = mcp.traffic.calls("whoami")[0].bearer
    grant = authorization.grants_by_access[first_token]

    wait_until(lambda: time.time() > grant.expires_at, what="the access token to expire")
    second = pal.call(SLUG, "whoami")

    assert json.loads(first["result"])["account"] == json.loads(second["result"])["account"] == "owner"
    refreshes = authorization.grant_requests("refresh_token")
    assert len(refreshes) == 1 and refreshes[0]["refresh_token"] == grant.refresh_token
    assert mcp.traffic.calls("whoami")[1].bearer != first_token
