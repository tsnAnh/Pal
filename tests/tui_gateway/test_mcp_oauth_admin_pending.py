"""An admin of the owner's organisation must approve Pal: the gateway says so with ``ADMIN_APPROVAL_PENDING``.

Vendor shapes are modelled by what the authorization server sends back, never by name in production code. Each
positive row cites where the shape comes from; the plain denial must stay an ordinary failure.
"""

import asyncio

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_constants import get_hermes_home
from tools.connectors.mcp_oauth_redirect import (
    ADMIN_APPROVAL_MESSAGE,
    GATEWAY_CALLBACK_PATH,
    is_admin_approval_pending,
)
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

ENTRA = "AADSTS90094: The grant requires admin permission."
ATLASSIAN = "Your site admin must authorize this app for the site 'acme.atlassian.net' before the app can access your account."
NOTION = "This connection is blocked by workspace policy. Ask a workspace owner or admin to approve the client."
SUPABASE = "An organization owner or admin must approve this app before it can access the organization."
SECRET_HINT = "vendor-detail-123"

PENDING = [
    pytest.param("consent_required", None, id="oidc-consent_required"),
    pytest.param("interaction_required", None, id="oidc-interaction_required"),
    pytest.param("access_denied", ENTRA, id="entra-access_denied-description"),
    pytest.param("access_denied", "Admin consent required for this application", id="admin-consent-description"),
    pytest.param(None, "Registration failed: 403 " + ATLASSIAN, id="atlassian-site-admin-text"),
    pytest.param(None, NOTION, id="notion-owner-or-admin-text"),
    pytest.param(None, SUPABASE, id="supabase-owner-or-admin-text"),
]

ORDINARY = [
    pytest.param("access_denied", None, id="plain-access_denied"),
    pytest.param("access_denied", "The user denied the request", id="user-denied-description"),
    pytest.param("invalid_grant", "The authorization code expired", id="expired-code"),
    pytest.param("server_error", "administrator rights are not required", id="admin-word-without-approval"),
    pytest.param(None, "Registration failed: 400 invalid_redirect_uri redirect_uri not allowed", id="registration-refusal"),
    pytest.param(None, "Timed out waiting for MCP OAuth callback", id="timeout"),
]


@pytest.mark.parametrize("error,description", PENDING)
def test_classifier_recognises_each_admin_shape(error, description):
    assert is_admin_approval_pending(error, description) is True


@pytest.mark.parametrize("error,description", ORDINARY)
def test_classifier_leaves_ordinary_failures_alone(error, description):
    assert is_admin_approval_pending(error, description) is False


@pytest.fixture(autouse=True)
def _clean_sessions(monkeypatch):
    monkeypatch.setattr(sessions, "_sessions", {})


@pytest.fixture
def vendor(monkeypatch):
    """A worker that publishes the authorization URL, waits for the callback, then fails like the SDK does."""
    plan = {"start_error": None}

    def worker(hermes_home, server_name, cfg, reconnect_live, *, flow, on_done=None, **_):
        try:
            if plan["start_error"]:
                raise RuntimeError(plan["start_error"])
            asyncio.run(flow.publish_authorization_url("https://as.example.com/authorize?client_id=x&state=s-1"))
            asyncio.run(flow.wait_for_callback(timeout=10))
            flow.mark_approved()
        except Exception as exc:
            flow.mark_error(str(exc))
        finally:
            flow.mark_worker_done()
            if on_done is not None:
                on_done()

    monkeypatch.setattr(sessions, "run_worker", worker)
    return plan


def _begin():
    return sessions.start_flow(
        str(get_hermes_home()), "srv", {"url": "https://mcp.example.com/mcp", "auth": "oauth"},
        client_redirect_uri="http://127.0.0.1:8412/callback")


def _refuse(result, **callback):
    rec = sessions._sessions[result["session_id"]]
    out = sessions.deliver_callback_flow(
        result["session_id"], "srv", code=None, state=rec["flow"].expected_state, **callback)
    assert out == {"ok": True, "session_id": result["session_id"]}
    assert rec["flow"].wait_worker_done(5)
    return sessions.poll_flow(result["session_id"], "srv")


@pytest.mark.parametrize("error,description", [p for p in PENDING if p.values[0]])
def test_a_refused_callback_polls_as_admin_pending_without_vendor_text(vendor, error, description):
    polled = _refuse(_begin(), error=error, error_description=description)
    assert polled["status"] == "error"
    assert polled["reason"] == "ADMIN_APPROVAL_PENDING"
    assert polled["error_message"] == ADMIN_APPROVAL_MESSAGE
    assert "AADSTS" not in str(polled) and "access_denied" not in str(polled)


@pytest.mark.parametrize("description", [None, "The user denied the request"])
def test_an_ordinary_denial_polls_as_a_plain_error(vendor, description):
    polled = _refuse(_begin(), error="access_denied", error_description=description)
    assert polled["status"] == "error"
    assert "reason" not in polled
    assert polled["error_message"] == "OAuth authorization failed: access_denied"


def test_the_description_is_judged_and_never_kept(vendor):
    polled = _refuse(_begin(), error="access_denied", error_description=f"{ENTRA} {SECRET_HINT}")
    flow = next(iter(sessions._sessions.values()))["flow"]
    assert SECRET_HINT not in str(flow.snapshot()) and SECRET_HINT not in str(polled)


def test_an_admin_refusal_found_while_starting_raises_the_typed_state(vendor):
    vendor["start_error"] = "Registration failed: 403 " + ATLASSIAN
    with pytest.raises(sessions.AdminApprovalPending) as raised:
        _begin()
    assert str(raised.value) == ADMIN_APPROVAL_MESSAGE
    assert "atlassian" not in str(raised.value)


def test_an_ordinary_failure_while_starting_stays_a_plain_error(vendor):
    vendor["start_error"] = "Registration failed: 500 upstream exploded"
    with pytest.raises(RuntimeError, match="upstream exploded") as raised:
        _begin()
    assert not isinstance(raised.value, sessions.AdminApprovalPending)


@pytest.fixture
def configured():
    (get_hermes_home() / "config.yaml").write_text(
        "mcp_servers:\n  srv:\n    url: https://mcp.example.com/mcp\n    auth: oauth\n")


def test_start_rpc_answers_admin_pending_with_a_plain_reason(vendor, configured):
    vendor["start_error"] = "Registration failed: 403 " + ATLASSIAN
    response = server._methods["mcp.servers.oauth.start"](
        1, {"name": "srv", "client_redirect_uri": "http://127.0.0.1:8412/callback"})
    assert response["error"]["data"] == {"reason": "ADMIN_APPROVAL_PENDING"}
    assert response["error"]["message"] == ADMIN_APPROVAL_MESSAGE


def test_start_rpc_keeps_an_ordinary_failure_without_the_state(vendor, configured):
    vendor["start_error"] = "Registration failed: 500 upstream exploded"
    response = server._methods["mcp.servers.oauth.start"](
        1, {"name": "srv", "client_redirect_uri": "http://127.0.0.1:8412/callback"})
    assert "data" not in response["error"]
    assert "upstream exploded" in response["error"]["message"]


def test_callback_rpc_carries_the_description_into_the_state(vendor, configured):
    started = server._methods["mcp.servers.oauth.start"](
        1, {"name": "srv", "client_redirect_uri": "http://127.0.0.1:8412/callback"})["result"]
    rec = sessions._sessions[started["session_id"]]
    relayed = server._methods["mcp.servers.oauth.callback"](1, {
        "name": "srv", "session_id": started["session_id"], "state": rec["flow"].expected_state,
        "error": "access_denied", "error_description": ENTRA})
    assert relayed["result"]["ok"] is True
    assert rec["flow"].wait_worker_done(5)
    polled = server._methods["mcp.servers.oauth.poll"](1, {"name": "srv", "session_id": started["session_id"]})["result"]
    assert polled["reason"] == "ADMIN_APPROVAL_PENDING"


def test_gateway_https_route_carries_the_description(vendor):
    from hermes_cli.web_routers import mcp_oauth_callback
    result = sessions.start_gateway_flow(
        str(get_hermes_home()), "srv", {"url": "https://mcp.example.com/mcp", "auth": "oauth"},
        "https://pal.example.com" + GATEWAY_CALLBACK_PATH)
    rec = sessions._sessions[result["session_id"]]
    app = FastAPI()
    app.include_router(mcp_oauth_callback.router)
    page = TestClient(app).get(GATEWAY_CALLBACK_PATH, params={
        "state": rec["flow"].expected_state, "error": "access_denied", "error_description": ENTRA})
    assert page.status_code == 200 and "AADSTS" not in page.text
    assert rec["flow"].wait_worker_done(5)
    assert sessions.poll_flow(result["session_id"], "srv")["reason"] == "ADMIN_APPROVAL_PENDING"
