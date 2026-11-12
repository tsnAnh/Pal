"""An MCP server that signs in on the owner's computer, after the one-time hand-over.

Invariants: reads, token refresh and approved actions run from the gateway-held tokens alone, with no computer
attached and no record of who signed in; a rejected refresh token is presented to the token endpoint once, then
every call gets the typed ``reauth_required`` error at once until a new hand-over, and the connector status every
app reads says so in plain words; a rotated refresh token reaches disk atomically with owner-only permissions.
"""

import json
import os
import stat
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from tests.tools.test_mcp_action_gate import Owner, _call, _register
from tests.tools.test_mcp_oauth_import import ACCESS, REFRESH, TOKEN_ENDPOINT, URL, _tokens
from tools import auth_required, mcp_oauth_import as imp
from tools.mcp_oauth import HermesTokenStorage, OwnerSigninRequired

REASON = "Sign in again: Upwork stopped accepting the saved sign-in"
ROTATED = "rt-rotated-9e41d27a"

pytest_plugins = ("tests.tools.test_mcp_action_gate",)


@pytest.fixture(autouse=True)
def fresh_manager():
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    yield
    reset_manager_for_tests()


@pytest.fixture
def home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def expire_access_token():
    path = HermesTokenStorage("upwork")._tokens_path()
    data = json.loads(path.read_text())
    data["expires_at"] = time.time() - 10
    path.write_text(json.dumps(data))


def refresh_grant(request, httpx):
    return httpx.Response(200, request=request, json={
        "access_token": "at-after-refresh", "token_type": "Bearer", "expires_in": 3600, "refresh_token": ROTATED})


def invalid_grant(request, httpx):
    return httpx.Response(400, request=request, json={"error": "invalid_grant"})


def through_the_provider(session, answer_token_endpoint):
    """Make ``session.call_tool`` send its request through the real OAuth provider, with a fake token endpoint."""
    from urllib.parse import parse_qs

    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool import sdk_httpx
    httpx = sdk_httpx()
    token_requests, bearers = [], []

    async def call_tool(name, arguments=None, **kwargs):
        provider = get_manager().get_or_build_provider("upwork", URL, {})
        flow = provider.async_auth_flow(httpx.Request("POST", URL))
        request = await flow.__anext__()
        while True:
            if str(request.url) == TOKEN_ENDPOINT:
                token_requests.append(parse_qs(request.content.decode()))
                response = answer_token_endpoint(request, httpx)
            else:
                bearers.append(request.headers.get("authorization"))
                response = httpx.Response(200, request=request)
            try:
                request = await flow.asend(response)
            except StopAsyncIteration:
                break
        return SimpleNamespace(content=[SimpleNamespace(type="text", text="ok")], isError=False, structuredContent=None)

    session.call_tool = AsyncMock(side_effect=call_tool)
    return token_requests, bearers


@pytest.fixture
def signed_in(home, server):
    import asyncio
    assert asyncio.run(imp.import_owner_tokens(home, "upwork", _tokens())) is None
    _register()
    return server


def test_no_computer_attached_a_read_a_refresh_and_an_approved_action_run_from_stored_tokens(signed_in):
    token_requests, bearers = through_the_provider(signed_in, refresh_grant)
    expire_access_token()
    with Owner() as chat:
        assert _call("search_jobs", {"q": "python"}) == {"result": "ok"}
        assert _call("submit_proposal", {"job_id": "~1", "cover_letter": "Hi"}) == {"result": "ok"}
    assert len(token_requests) == 1 and token_requests[0]["refresh_token"] == [REFRESH]
    assert bearers == ["Bearer at-after-refresh"] * 2
    assert len(chat.cards) == 1 and chat.cards[0]["draft"]["subject"] == "submit_proposal"
    stored = json.loads(HermesTokenStorage("upwork")._tokens_path().read_text())
    assert stored["refresh_token"] == ROTATED


def test_a_rejected_refresh_token_is_presented_once_and_every_call_then_gets_the_typed_error(signed_in):
    token_requests, _ = through_the_provider(signed_in, invalid_grant)
    expire_access_token()
    results = [_call("search_jobs") for _ in range(3)]
    assert [r["code"] for r in results] == ["reauth_required"] * 3 == [auth_required.REAUTH_REQUIRED] * 3
    assert all(REASON in r["error"] and r["server"] == "upwork" for r in results)
    assert len(token_requests) == 1, "the dead refresh token must reach the token endpoint exactly once"
    assert signed_in.call_tool.await_count == 1, "later calls fail before any request is made"
    assert HermesTokenStorage("upwork").reauth_required()


def test_a_gated_action_is_refused_before_a_card_is_shown_while_sign_in_is_dead(signed_in):
    through_the_provider(signed_in, invalid_grant)
    expire_access_token()
    _call("search_jobs")
    with Owner() as chat:
        result = _call("submit_proposal", {"job_id": "~1"})
    assert result["code"] == "reauth_required" and chat.cards == []


def test_the_refusal_survives_a_restart_and_a_reconnect(signed_in):
    from tools.mcp_oauth_manager import get_manager
    token_requests, _ = through_the_provider(signed_in, invalid_grant)
    expire_access_token()
    _call("search_jobs")
    get_manager().evict("upwork")
    assert _call("search_jobs")["code"] == "reauth_required"
    assert len(token_requests) == 1


def test_the_provider_stops_before_the_network_and_opens_no_browser_flow(signed_in):
    import asyncio

    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool import sdk_httpx
    httpx = sdk_httpx()
    through_the_provider(signed_in, invalid_grant)
    expire_access_token()
    _call("search_jobs")

    async def first_request():
        provider = get_manager().get_or_build_provider("upwork", URL, {})
        await provider.async_auth_flow(httpx.Request("POST", URL)).__anext__()

    with pytest.raises(OwnerSigninRequired):
        asyncio.run(first_request())


def test_a_server_error_from_the_token_endpoint_is_not_a_dead_sign_in(signed_in):
    def unavailable(request, httpx):
        return httpx.Response(503, request=request, text="try later")
    first, _ = through_the_provider(signed_in, unavailable)
    expire_access_token()
    _call("search_jobs")
    assert len(first) == 1 and not HermesTokenStorage("upwork").reauth_required()
    second, _ = through_the_provider(signed_in, refresh_grant)
    assert _call("search_jobs") == {"result": "ok"} and len(second) == 1, "the saved refresh token is still tried"


def _rows():
    from unittest.mock import patch

    from tools import mcp_tool
    from tui_gateway import server as rpc
    with patch.dict(mcp_tool._servers, {}, clear=True):
        replies = [rpc._methods[method](1, {}) for method in ("mcp.catalog", "mcp.servers.status")]
    assert all("error" not in reply for reply in replies), replies
    catalog, status = (reply["result"]["servers"] for reply in replies)
    return ({e["name"]: e for e in catalog}["upwork"], {e["name"]: e for e in status}["upwork"])


def test_every_app_reads_the_reason_from_the_catalog_and_the_status_until_a_new_hand_over(signed_in, home):
    import asyncio
    through_the_provider(signed_in, invalid_grant)
    catalog, status = _rows()
    assert catalog["needs_auth_reason"] is None and not status["needs_auth"]
    expire_access_token()
    _call("search_jobs")
    catalog, status = _rows()
    assert catalog["needs_auth_reason"] == REASON and catalog["signin_on"] == "owner_app"
    assert status["needs_auth"] is True and status["needs_auth_reason"] == REASON
    assert asyncio.run(imp.import_owner_tokens(home, "upwork", _tokens(refresh_token="rt-new-3b7c"))) is None
    catalog, status = _rows()
    assert catalog["needs_auth_reason"] is None and not status["needs_auth"]
    assert not HermesTokenStorage("upwork").reauth_required()
    token_requests, bearers = through_the_provider(signed_in, refresh_grant)
    assert _call("search_jobs") == {"result": "ok"} and token_requests == [] and bearers == [f"Bearer {ACCESS}"]


def test_the_typed_error_raises_the_mac_prompt_without_holding_the_turn(monkeypatch):
    offered = []
    monkeypatch.setattr("gateway.auth_prompts.offer_from_thread", lambda *args: offered.append(args[1]))
    monkeypatch.setattr("gateway.auth_prompts.call_from_thread",
                        lambda *args: pytest.fail("the turn must not wait for the sign-in"))
    result = auth_required.reauth_required_result("upwork")
    assert auth_required.resolve("mcp_upwork_search_jobs", {}, result, lambda: pytest.fail("no retry")) == result
    assert [need.service for need in offered] == ["mcp:upwork"]


def test_the_sign_in_state_lives_in_owner_only_files_and_no_token_reaches_config_or_logs(home, caplog):
    import asyncio
    caplog.set_level("DEBUG")
    assert asyncio.run(imp.import_owner_tokens(home, "upwork", _tokens())) is None
    folder = home / "mcp-tokens"
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700
    files = sorted(folder.iterdir())
    assert {p.name for p in files} >= {"upwork.json", "upwork.client.json", "upwork.meta.json"}
    assert all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in files if p.is_file())
    assert ACCESS not in (home / "config.yaml").read_text() and REFRESH not in (home / "config.yaml").read_text()
    assert ACCESS not in caplog.text and REFRESH not in caplog.text


def test_a_crash_before_the_rename_leaves_the_previous_tokens_intact_and_loadable(home, monkeypatch):
    import asyncio

    from mcp.shared.auth import OAuthToken
    import utils
    assert asyncio.run(imp.import_owner_tokens(home, "upwork", _tokens())) is None
    storage = HermesTokenStorage("upwork", hermes_home=home)
    before = storage._tokens_path().read_bytes()

    def crash(tmp_path, destination):
        raise OSError("power cut before the rename")
    monkeypatch.setattr(utils, "atomic_replace", crash)
    rotated = OAuthToken(access_token="at-rotated", token_type="Bearer", expires_in=3600, refresh_token=ROTATED)
    with pytest.raises(OSError):
        asyncio.run(storage.set_tokens(rotated))
    assert storage._tokens_path().read_bytes() == before
    survivor = asyncio.run(storage.get_tokens())
    assert survivor.access_token == ACCESS and survivor.refresh_token == REFRESH
    assert sorted(p.name for p in storage._tokens_path().parent.glob("*.tmp")) == [], "no half-written file is left"
    monkeypatch.undo()
    asyncio.run(storage.set_tokens(rotated))
    assert asyncio.run(storage.get_tokens()).refresh_token == ROTATED
    assert stat.S_IMODE(os.stat(storage._tokens_path()).st_mode) == 0o600
