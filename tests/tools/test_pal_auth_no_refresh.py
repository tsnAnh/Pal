from __future__ import annotations

import asyncio
import json

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import APP, OAuthServerDouble
from tools.auth_required import detect
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-no-refresh-token"
SLUG = "palnorefresh"
CALLS_AFTER_EXPIRY = 3


@pytest.fixture
def servers():
    with OAuthServerDouble(accepted_redirects=frozenset({APP}), issue_refresh=False) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def sign_in(pal, authorization, mcp) -> None:
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    pal.sign_in_with_app_redirect(SLUG)
    pal.start_agent_tools()


def server_row(pal) -> dict:
    return next(r for r in pal.rpc("mcp.servers.status")["servers"] if r["name"] == SLUG)


def test_a_server_that_issues_no_refresh_token_works_until_the_token_expires(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)

    answer = pal.call(SLUG, "whoami")

    assert json.loads(answer["result"])["account"] == "owner"
    assert asyncio.run(HermesTokenStorage(f"{SLUG}@default").get_tokens()).refresh_token is None
    assert server_row(pal)["connected"] is True and server_row(pal)["needs_auth"] is False


def test_an_expired_token_without_a_refresh_token_asks_for_a_new_sign_in_and_never_loops(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    pal.call(SLUG, "whoami")
    authorization.expire_access_tokens()
    rejected_before = mcp.traffic.rejected()

    results = [pal.call(SLUG, "whoami") for _ in range(CALLS_AFTER_EXPIRY)]
    settled = mcp.traffic.rejected()
    pal.call(SLUG, "whoami")

    assert all("error" in r and "result" not in r for r in results)
    assert authorization.grant_requests("refresh_token") == []
    assert len(authorization.grant_requests("authorization_code")) == 1
    assert settled > rejected_before and mcp.traffic.rejected() == settled
    row = server_row(pal)
    assert row["needs_auth"] is True and row["connected"] is False and row["status"] == "failed"
    assert len(mcp.traffic.calls("whoami")) == 1


@pytest.mark.xfail(strict=True, reason=(
    "the first call after expiry answers a transport error, and connectors.catalog derives needs_reconnect "
    "only from the rejected-refresh marker, so neither tells the owner to sign in again"))
def test_the_owner_is_told_to_sign_in_again_after_the_token_expired(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    authorization.expire_access_tokens()

    failed = pal.call(SLUG, "whoami")

    assert detect(pal.tool(SLUG, "whoami"), {}, json.dumps(failed)) is not None
    assert pal.connector_row(SLUG)["status"] == "needs_reconnect"
