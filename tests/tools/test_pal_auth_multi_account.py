from __future__ import annotations

import json

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import APP, OAuthServerDouble

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "multi-account"
SLUG = "palmulti"


@pytest.fixture
def servers():
    with OAuthServerDouble(accepted_redirects=frozenset({APP})) as authorization, McpServerDouble(
            protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        yield authorization, mcp


def served_account(result: dict) -> str:
    return json.loads(result["result"])["account"]


def connect_accounts(pal, authorization, mcp, accounts: dict[str, str | None]) -> None:
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    for index, (alias, identity) in enumerate(accounts.items()):
        authorization.sign_in_as(identity)
        extra = {"account": alias, "create": True} if index else {}
        pal.sign_in_with_app_redirect(SLUG, **extra)
    pal.start_agent_tools()


def test_a_single_account_needs_no_alias(servers, pal):
    authorization, mcp = servers
    connect_accounts(pal, authorization, mcp, {"default": "alice"})

    plain = pal.call(SLUG, "whoami")
    named = pal.call(SLUG, "whoami", connector_alias="default")

    assert served_account(plain) == served_account(named) == "alice"
    row = pal.connector_row(SLUG)
    assert row["multi_account"] is True and [a["name"] for a in row["accounts"]] == ["default"]


def test_two_accounts_of_one_connector_are_routed_to_their_own_token_by_alias(servers, pal):
    authorization, mcp = servers
    connect_accounts(pal, authorization, mcp, {"default": "alice", "work": "bob"})

    first = pal.call(SLUG, "whoami", connector_alias="work")
    second = pal.call(SLUG, "whoami", connector_alias="default")
    third = pal.call(SLUG, "list_projects", connector_alias="work", limit=2)

    assert [served_account(r) for r in (first, second, third)] == ["bob", "alice", "bob"]
    calls = mcp.traffic.tool_calls
    assert [c.account for c in calls] == ["bob", "alice", "bob"]
    assert len({c.bearer for c in calls if c.account == "bob"}) == 1
    assert {c.bearer for c in calls if c.account == "bob"}.isdisjoint({c.bearer for c in calls if c.account == "alice"})
    assert all("connector_alias" not in c.arguments for c in calls)
    assert [a["name"] for a in pal.connector_row(SLUG)["accounts"]] == ["default", "work"]
    assert pal.connector_row(SLUG)["status"] == "connected"


def test_several_accounts_without_an_alias_name_them_and_reach_no_server(servers, pal):
    authorization, mcp = servers
    connect_accounts(pal, authorization, mcp, {"default": "alice", "work": "bob"})

    missing = pal.call(SLUG, "whoami")
    unknown = pal.call(SLUG, "whoami", connector_alias="nobody")

    for refusal in (missing, unknown):
        assert "default" in refusal["error"] and "work" in refusal["error"] and "connector_alias" in refusal["error"]
    assert mcp.traffic.tool_calls == []


def test_the_second_account_is_signed_in_with_an_account_prompt_on_a_private_window_hint(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    authorization.sign_in_as("alice")
    pal.sign_in_with_app_redirect(SLUG)
    authorization.sign_in_as("bob")

    second = pal.sign_in_with_app_redirect(SLUG, account="work", create=True)

    assert "prompt" not in authorization.authorize_queries[0]
    assert authorization.authorize_queries[1]["prompt"] == "select_account login"
    assert second["private_window_hint"] is True
