from __future__ import annotations

import asyncio
import json
import time

import pytest

from tests.tools.mcp_bearer_server_double import McpServerDouble, Protection
from tests.tools.oauth_server_double import APP, OAuthServerDouble
from tests.waiting import wait_until
from tools.auth_required import detect
from tools.mcp_accounts import service_for_server
from tools.mcp_oauth import HermesTokenStorage
from tools.registry import registry

pytest_plugins = ("tests.tools.pal_auth_harness",)

SHAPE = "oauth-no-refresh-token"
SLUG = "palnorefresh"
CALLS_AFTER_EXPIRY = 3
FAST = 5.0
SHORT_LIVED = 2


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


def reauth_need(pal, failed: dict, account: str = "default"):
    need = detect(pal.tool(SLUG, "whoami"), {}, json.dumps(failed))
    assert need is not None and need.service == service_for_server(f"{SLUG}@{account}")
    return need


def test_the_owner_is_told_to_sign_in_again_after_the_token_expired(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    authorization.expire_access_tokens()

    started = time.monotonic()
    failed = pal.call(SLUG, "whoami")
    waited = time.monotonic() - started

    reauth_need(pal, failed)
    assert failed["code"] == "reauth_required" and failed["needs_reauth"] is True
    assert waited < FAST
    assert pal.connector_row(SLUG)["status"] == "needs_reconnect"
    row = server_row(pal)
    assert row["needs_auth"] is True and row["connected"] is False


def test_the_tools_stay_registered_and_keep_asking_for_a_new_sign_in_until_the_owner_signs_in(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    registered = pal.start_agent_tools()
    authorization.expire_access_tokens()

    answers = [pal.call(SLUG, "whoami") for _ in range(CALLS_AFTER_EXPIRY)]

    assert all(a["code"] == "reauth_required" and "Unknown tool" not in json.dumps(a) for a in answers)
    assert all(pal.tool(SLUG, name) in registered for name in ("whoami", "list_projects"))
    assert all(registry.get_entry(pal.tool(SLUG, name)) is not None for name in ("whoami", "list_projects"))
    assert len(mcp.traffic.calls("whoami")) == 0

    pal.sign_in_with_app_redirect(SLUG)
    recovered = pal.call(SLUG, "whoami")

    assert json.loads(recovered["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"
    assert server_row(pal)["needs_auth"] is False


def test_a_token_that_ran_out_by_its_own_clock_is_refused_before_any_network(pal):
    with OAuthServerDouble(accepted_redirects=frozenset({APP}), issue_refresh=False, expires_in=SHORT_LIVED) as authorization, \
            McpServerDouble(protection=Protection.OAUTH, authorization_server=authorization) as mcp:
        sign_in(pal, authorization, mcp)
        expires_at = time.time() + SHORT_LIVED
        assert json.loads(pal.call(SLUG, "whoami")["result"])["account"] == "owner"
        wait_until(lambda: time.time() > expires_at, what="the token to run out")
        seen_before = len(mcp.traffic.statuses)
        token_requests_before = len(authorization.token_requests)

        started = time.monotonic()
        answers = [pal.call(SLUG, "whoami") for _ in range(CALLS_AFTER_EXPIRY)]

        assert time.monotonic() - started < FAST
        reauth_need(pal, answers[0])
        assert all(a["code"] == "reauth_required" for a in answers)
        assert len(mcp.traffic.statuses) == seen_before and len(authorization.token_requests) == token_requests_before
        assert len(authorization.registrations) == 1
        assert pal.connector_row(SLUG)["status"] == "needs_reconnect"


def test_only_the_account_whose_token_expired_asks_for_a_new_sign_in(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    authorization.sign_in_as("alice")
    pal.sign_in_with_app_redirect(SLUG)
    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work", create=True)
    pal.start_agent_tools()
    authorization.expire_access_tokens("bob")

    work = pal.call(SLUG, "whoami", connector_alias="work")
    personal = pal.call(SLUG, "whoami", connector_alias="default")

    reauth_need(pal, work, "work")
    assert work["server"] == f"{SLUG}@work"
    assert json.loads(personal["result"])["account"] == "alice"
    row = pal.connector_row(SLUG)
    assert {a["name"]: a["status"] for a in row["accounts"]} == {"default": "connected", "work": "needs_reconnect"}
    assert row["status"] == "connected"
    listed = next(r for r in pal.rpc("mcp.catalog")["servers"] if r["name"] == SLUG)
    assert {a["name"]: a["status"] for a in listed["accounts"]} == {"default": "connected", "work": "needs_reconnect"}
    status = {r.get("account"): r for r in pal.rpc("mcp.servers.status")["servers"] if r["name"] == SLUG}
    assert status["work"]["needs_auth"] is True and status["default"]["needs_auth"] is False


def traffic_marks(authorization, mcp) -> tuple[int, int]:
    return len(mcp.traffic.statuses), len(authorization.token_requests)


def test_a_restart_with_a_dead_sign_in_keeps_the_tools_and_asks_for_a_new_sign_in_without_any_traffic(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    pal.call(SLUG, "whoami")
    authorization.expire_access_tokens()
    assert pal.call(SLUG, "whoami")["code"] == "reauth_required"

    pal.restart_process(SLUG)
    before = traffic_marks(authorization, mcp)
    registered = pal.start_agent_tools()
    started = time.monotonic()
    answers = [pal.call(SLUG, "whoami") for _ in range(CALLS_AFTER_EXPIRY)]

    assert all(pal.tool(SLUG, name) in registered for name in ("whoami", "list_projects"))
    assert all(a["code"] == "reauth_required" and a["needs_reauth"] is True for a in answers)
    assert time.monotonic() - started < FAST
    reauth_need(pal, answers[0])
    assert traffic_marks(authorization, mcp) == before
    row = server_row(pal)
    assert row["needs_auth"] is True and row["connected"] is False
    assert pal.connector_row(SLUG)["status"] == "needs_reconnect"

    pal.sign_in_with_app_redirect(SLUG)
    recovered = pal.call(SLUG, "whoami")

    assert json.loads(recovered["result"])["account"] == "owner"
    assert pal.connector_row(SLUG)["status"] == "connected"
    assert server_row(pal)["needs_auth"] is False


def test_a_restart_with_a_dead_sign_in_and_no_cached_tools_registers_nothing_but_still_asks_for_a_new_sign_in(servers, pal):
    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    authorization.expire_access_tokens()
    pal.call(SLUG, "whoami")
    pal.restart_process(SLUG)
    (pal.home / "cache" / "mcp_schema_cache.json").unlink(missing_ok=True)
    before = traffic_marks(authorization, mcp)

    registered = pal.start_agent_tools()

    assert not any(name.startswith(pal.tool(SLUG, "")) for name in registered)
    assert traffic_marks(authorization, mcp) == before
    row = server_row(pal)
    assert row["needs_auth"] is True and row["connected"] is False


def test_a_restart_keeps_every_account_of_a_connector_and_only_the_dead_one_asks_for_a_new_sign_in(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    authorization.sign_in_as("alice")
    pal.sign_in_with_app_redirect(SLUG)
    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work", create=True)
    pal.start_agent_tools()
    authorization.expire_access_tokens("bob")
    assert pal.call(SLUG, "whoami", connector_alias="work")["code"] == "reauth_required"

    pal.restart_process(SLUG)
    rejected_before = mcp.traffic.rejected()
    tokens_before = len(authorization.token_requests)
    registered = pal.start_agent_tools()
    assert mcp.traffic.rejected() == rejected_before and len(authorization.token_requests) == tokens_before
    settled = len(mcp.traffic.statuses)
    work = [pal.call(SLUG, "whoami", connector_alias="work") for _ in range(CALLS_AFTER_EXPIRY)]
    personal = pal.call(SLUG, "whoami", connector_alias="default")

    assert pal.tool(SLUG, "whoami") in registered
    assert all(a["code"] == "reauth_required" and a["server"] == f"{SLUG}@work" for a in work)
    assert json.loads(personal["result"])["account"] == "alice"
    assert [c.account for c in mcp.traffic.calls("whoami")] == ["alice"]
    status = {r.get("account"): r for r in pal.rpc("mcp.servers.status")["servers"] if r["name"] == SLUG}
    assert status["work"]["needs_auth"] is True and status["default"]["needs_auth"] is False
    assert len(mcp.traffic.statuses) > settled

    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work")
    recovered = pal.call(SLUG, "whoami", connector_alias="work")

    assert json.loads(recovered["result"])["account"] == "bob"
    assert {a["name"]: a["status"] for a in pal.connector_row(SLUG)["accounts"]} == {"default": "connected", "work": "connected"}


def test_a_restart_where_every_account_is_dead_keeps_the_tools_and_each_account_recovers_on_its_own_sign_in(servers, pal):
    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    authorization.sign_in_as("alice")
    pal.sign_in_with_app_redirect(SLUG)
    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work", create=True)
    pal.start_agent_tools()
    authorization.expire_access_tokens()
    for alias in ("default", "work"):
        got = pal.call(SLUG, "whoami", connector_alias=alias)
        assert got.get("code") == "reauth_required", got

    pal.restart_process(SLUG)
    before = traffic_marks(authorization, mcp)
    registered = pal.start_agent_tools()
    answers = {alias: pal.call(SLUG, "whoami", connector_alias=alias) for alias in ("default", "work")}

    assert all(pal.tool(SLUG, name) in registered for name in ("whoami", "list_projects"))
    assert {alias: a["server"] for alias, a in answers.items()} == {"default": f"{SLUG}@default", "work": f"{SLUG}@work"}
    assert all(a["code"] == "reauth_required" for a in answers.values())
    assert traffic_marks(authorization, mcp) == before

    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work")

    assert json.loads(pal.call(SLUG, "whoami", connector_alias="work")["result"])["account"] == "bob"
    assert pal.call(SLUG, "whoami", connector_alias="default")["code"] == "reauth_required"


def test_a_live_account_going_away_leaves_the_tools_a_dead_sibling_account_still_needs(servers, pal):
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    authorization, mcp = servers
    pal.add_connector(SLUG, "mcp_oauth", mcp.mcp_url)
    pal.rpc("mcp.servers.add", name=SLUG, preset=SLUG)
    authorization.sign_in_as("alice")
    pal.sign_in_with_app_redirect(SLUG)
    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work", create=True)
    pal.start_agent_tools()
    authorization.expire_access_tokens("bob")
    assert pal.call(SLUG, "whoami", connector_alias="work")["code"] == "reauth_required"
    pal.restart_process(SLUG)
    registered = pal.start_agent_tools()
    assert pal.tool(SLUG, "whoami") in registered

    shutdown_mcp_servers(names={f"{SLUG}@default"})

    assert all(registry.get_entry(pal.tool(SLUG, name)) is not None for name in ("whoami", "list_projects"))
    answer = pal.call(SLUG, "whoami", connector_alias="work")
    assert answer["code"] == "reauth_required" and answer["server"] == f"{SLUG}@work"

    authorization.sign_in_as("bob")
    pal.sign_in_with_app_redirect(SLUG, account="work")

    assert json.loads(pal.call(SLUG, "whoami", connector_alias="work")["result"])["account"] == "bob"


def test_a_call_whose_transport_failed_after_the_sign_in_check_still_gets_the_sign_in_again_error(servers, pal, monkeypatch):
    from tools import mcp_tool_handlers as handlers
    from tools.mcp_tool_scope import _resolve_server_key
    from tools import mcp_tool as core

    authorization, mcp = servers
    sign_in(pal, authorization, mcp)
    pal.call(SLUG, "whoami")
    authorization.expire_access_tokens()
    name = f"{SLUG}@default"
    gate = handlers._trust_gate_check

    def transport_fails_then_marker_lands(*args, **kwargs):
        verdict = gate(*args, **kwargs)
        server = core._servers[_resolve_server_key(name)]
        server.session = None
        server._ready.clear()
        HermesTokenStorage(name).mark_reauth_required("token_rejected")
        return verdict

    monkeypatch.setattr(handlers, "_trust_gate_check", transport_fails_then_marker_lands)
    started = time.monotonic()
    answer = pal.call(SLUG, "whoami")

    assert answer["code"] == "reauth_required" and answer["needs_reauth"] is True
    assert time.monotonic() - started < FAST
    assert len(mcp.traffic.calls("whoami")) == 1
