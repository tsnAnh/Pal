"""The Pal app's MCP sign-in redirect chain: app scheme, then the gateway's https callback, then loopback.

Vendors are modelled by what their registration endpoint accepts, never by name in production code:
  scheme_and_https (Linear-like): takes the app scheme
  https_only (Stripe-like): refuses the app scheme, takes https
  loopback_only (Vercel-like): refuses the app scheme and https, takes loopback
"""

import asyncio
import logging
import time

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_constants import get_hermes_home
from tools.connectors import mcp_oauth
from tools.connectors.mcp_oauth import _validate_client_redirect_uri
from tools.connectors.mcp_oauth_redirect import (
    APP_DONE_URL,
    APP_REDIRECT_URI,
    GATEWAY_CALLBACK_PATH,
    is_registration_refusal,
)
from tests.waiting import wait_until
from tools.mcp_oauth import HermesTokenStorage
from tui_gateway import mcp_oauth_sessions as sessions

PUBLIC = "https://pal.example.com"
GATEWAY_URI = PUBLIC + GATEWAY_CALLBACK_PATH
CFG = {"url": "https://mcp.example.com/mcp", "auth": "oauth"}
REFUSAL = 'Registration failed: 400 {"error":"invalid_redirect_uri","error_description":"redirect_uri not allowed"}'

ACCEPTS = {
    "scheme_and_https": lambda uri: True,
    "https_only": lambda uri: uri.startswith("https://") or uri.startswith("http://127.0.0.1"),
    "loopback_only": lambda uri: uri.startswith("http://127.0.0.1"),
}


@pytest.fixture(autouse=True)
def _clean_sessions(monkeypatch):
    monkeypatch.setattr(sessions, "_sessions", {})
    yield


@pytest.fixture
def vendor(monkeypatch):
    """Install a fake worker that registers the redirect the flow carries, as a DCR endpoint would."""
    attempts: list[str] = []
    state = {"accepts": ACCEPTS["scheme_and_https"], "fail_with": None, "n": 0}

    def worker(hermes_home, server_name, cfg, reconnect_live, *, flow, on_done=None, **_):
        attempts.append(flow.redirect_uri)
        try:
            if state["fail_with"]:
                raise RuntimeError(state["fail_with"])
            if not state["accepts"](flow.redirect_uri):
                raise RuntimeError(REFUSAL)
            state["n"] += 1
            asyncio.run(flow.publish_authorization_url(
                f"https://as.example.com/authorize?client_id=x&state=state-{state['n']}-secret"))
            asyncio.run(flow.wait_for_callback(timeout=10))
            flow.mark_approved()
        except Exception as exc:
            flow.mark_error(str(exc))
        finally:
            flow.mark_worker_done()
            if on_done is not None:
                on_done()

    monkeypatch.setattr(sessions, "run_worker", worker)
    state["attempts"] = attempts
    return state


def use(vendor, kind):
    vendor["accepts"] = ACCEPTS[kind]


def set_public_url(url):
    (get_hermes_home() / "config.yaml").write_text(f"webapp:\n  public_url: {url}\n")


def start(name="srv", **kw):
    return sessions.start_flow(str(get_hermes_home()), name, dict(CFG), client_redirect_uri=APP_REDIRECT_URI, **kw)


def finish(result, name="srv", state=None):
    rec = sessions._sessions[result["session_id"]]
    state = state or rec["flow"].expected_state
    sessions.deliver_callback_flow(result["session_id"], name, code="the-code", state=state)
    assert rec["flow"].wait_worker_done(5)
    return rec


def stop(result, name="srv"):
    sessions.cancel_flow(result["session_id"], name, str(get_hermes_home()))
    assert sessions._sessions[result["session_id"]]["flow"].wait_worker_done(5)


@pytest.mark.parametrize("uri,expected", [
    ("dev.tsnanh.hermes.bot:/mcp-oauth/callback", "dev.tsnanh.hermes.bot:/mcp-oauth/callback"),
    ("  DEV.tsnanh.hermes.bot:/x/y ", "dev.tsnanh.hermes.bot:/x/y"),
    ("http://127.0.0.1:8412/callback", "http://127.0.0.1:8412/callback"),
])
def test_validator_accepts_app_scheme_and_loopback(uri, expected):
    assert _validate_client_redirect_uri(uri) == expected


@pytest.mark.parametrize("uri", [
    "dev.tsnanh.hermes.bot://evil/callback", "dev.tsnanh.hermes.bot:/", "dev.tsnanh.hermes.bot:",
    "dev.tsnanh.hermes.bot://user@host/x", "dev.tsnanh.hermes.bot:/x?a=1", "other.app:/mcp-oauth/callback",
    "https://pal.example.com/webapp/mcp-oauth/callback", "http://pal.example.com/callback", "javascript:alert(1)",
])
def test_validator_rejects_everything_else(uri):
    with pytest.raises(ValueError):
        _validate_client_redirect_uri(uri)


@pytest.mark.parametrize("text,expected", [
    (REFUSAL, True),
    ('Registration failed: 400 {"error":"invalid_client_metadata"}', True),
    ("Registration failed: 400 redirect_uris must use https or loopback", True),
    ("Registration failed: 422 Only https redirect URIs are allowed", True),
    ("Registration failed: 403 forbidden", False),
    ("Registration failed: 500 invalid_redirect_uri", False),
    ("Timed out waiting for MCP authorization URL", False),
    ("", False),
])
def test_refusal_classifier(text, expected):
    assert is_registration_refusal(text) is expected


def test_app_scheme_accepted_first(vendor):
    set_public_url(PUBLIC)
    result = start()
    assert vendor["attempts"] == [APP_REDIRECT_URI]
    assert (result["redirect"], result["redirect_uri"]) == ("app", APP_REDIRECT_URI)
    assert "notice" not in result
    assert sessions.poll_flow(result["session_id"], "srv")["redirect"] == "app"
    finish(result)


def test_https_vendor_falls_forward_to_gateway_and_is_remembered(vendor):
    set_public_url(PUBLIC)
    use(vendor, "https_only")
    result = start()
    assert vendor["attempts"] == [APP_REDIRECT_URI, GATEWAY_URI]
    assert (result["redirect"], result["redirect_uri"]) == ("gateway", GATEWAY_URI)
    assert sessions.poll_flow(result["session_id"], "srv")["redirect"] == "gateway"
    assert [r["redirect"] for r in sessions._sessions.values()] == ["gateway"]
    rec = sessions._sessions[result["session_id"]]
    assert sessions.deliver_gateway_callback(rec["flow"].expected_state, code="the-code")
    assert rec["flow"].wait_worker_done(5)
    assert sessions.poll_flow(result["session_id"], "srv")["status"] == "approved"
    wait_until(lambda: HermesTokenStorage("srv").redirect_pref().get("kind") == "gateway", what="preference saved")

    vendor["attempts"].clear()
    again = start()
    assert vendor["attempts"] == [GATEWAY_URI]
    assert again["redirect"] == "gateway"
    stop(again)


def test_loopback_vendor_uses_client_hosted_fallback(vendor):
    set_public_url(PUBLIC)
    use(vendor, "loopback_only")
    result = start(fallback_redirect_uri="http://127.0.0.1:49152/callback")
    assert vendor["attempts"] == [APP_REDIRECT_URI, GATEWAY_URI, "http://127.0.0.1:49152/callback"]
    assert (result["redirect"], result["redirect_uri"]) == ("loopback", "http://127.0.0.1:49152/callback")
    assert sessions._sessions[result["session_id"]]["httpd"] is None
    finish(result)


def test_loopback_vendor_without_fallback_uses_gateway_receiver(vendor):
    set_public_url(PUBLIC)
    use(vendor, "loopback_only")
    bound = []
    real = mcp_oauth._start_loopback_receiver
    vendor_receiver = lambda flow: bound.append(flow) or real(flow)
    mcp_oauth._start_loopback_receiver = vendor_receiver
    try:
        result = start()
    finally:
        mcp_oauth._start_loopback_receiver = real
    assert result["redirect"] == "loopback"
    assert result["redirect_uri"].startswith("http://127.0.0.1:")
    assert len(bound) == 1
    finish(result)


def test_no_public_url_skips_gateway_and_explains_once(vendor):
    use(vendor, "loopback_only")
    first = start(fallback_redirect_uri="http://127.0.0.1:49152/callback")
    assert vendor["attempts"] == [APP_REDIRECT_URI, "http://127.0.0.1:49152/callback"]
    assert first["redirect"] == "loopback"
    assert "public address" in first["notice"]
    stop(first)

    vendor["attempts"].clear()
    second = start(fallback_redirect_uri="http://127.0.0.1:49152/callback")
    assert vendor["attempts"] == [APP_REDIRECT_URI, "http://127.0.0.1:49152/callback"]
    assert "notice" not in second
    stop(second)


def test_http_public_url_is_not_a_gateway_redirect(vendor):
    set_public_url("http://pal.example.com")
    use(vendor, "loopback_only")
    result = start(fallback_redirect_uri="http://127.0.0.1:49152/callback")
    assert vendor["attempts"] == [APP_REDIRECT_URI, "http://127.0.0.1:49152/callback"]
    stop(result)


def test_other_failures_do_not_walk_the_chain(vendor):
    set_public_url(PUBLIC)
    vendor["fail_with"] = "Registration failed: 403 forbidden"
    with pytest.raises(RuntimeError, match="403"):
        start()
    assert vendor["attempts"] == [APP_REDIRECT_URI]


def test_refusal_at_last_step_raises(vendor):
    set_public_url(PUBLIC)
    vendor["accepts"] = lambda uri: False
    with pytest.raises(RuntimeError, match="invalid_redirect_uri"):
        start(fallback_redirect_uri="http://127.0.0.1:49152/callback")
    assert vendor["attempts"] == [APP_REDIRECT_URI, GATEWAY_URI, "http://127.0.0.1:49152/callback"]
    assert not [r for r in sessions._sessions.values() if not r["flow"].worker_done]


def test_refused_attempts_leave_no_session_behind(vendor):
    set_public_url(PUBLIC)
    use(vendor, "https_only")
    result = start()
    assert list(sessions._sessions) == [result["session_id"]]
    stop(result)


def test_loopback_client_redirect_is_unchanged_except_redirect_field(vendor):
    result = sessions.start_flow(
        str(get_hermes_home()), "srv", dict(CFG), client_redirect_uri="http://127.0.0.1:8412/callback")
    assert vendor["attempts"] == ["http://127.0.0.1:8412/callback"]
    assert (result["redirect"], result["redirect_uri"]) == ("loopback", "http://127.0.0.1:8412/callback")
    stop(result)


def test_no_client_redirect_uses_gateway_receiver_and_reports_loopback(vendor):
    result = sessions.start_flow(str(get_hermes_home()), "srv", dict(CFG))
    assert result["redirect"] == "loopback"
    assert result["redirect_uri"].startswith("http://127.0.0.1:")
    stop(result)


def test_fallback_must_be_loopback_http(vendor):
    for bad in (APP_REDIRECT_URI, "https://evil.example.com/cb", "http://evil.example.com:80/cb"):
        with pytest.raises(ValueError):
            start(fallback_redirect_uri=bad)
    assert vendor["attempts"] == []


def test_remembered_kind_is_per_profile_and_per_server(vendor, tmp_path):
    set_public_url(PUBLIC)
    finish(start("alpha"), "alpha")
    wait_until(lambda: HermesTokenStorage("alpha").redirect_pref().get("kind") == "app", what="preference saved")
    assert HermesTokenStorage("beta").redirect_pref() == {}
    assert HermesTokenStorage("alpha", hermes_home=tmp_path / "other-profile").redirect_pref() == {}


def _arm_gateway_flow(vendor):
    set_public_url(PUBLIC)
    use(vendor, "https_only")
    result = start()
    return result, sessions._sessions[result["session_id"]]


def test_gateway_state_is_single_use(vendor):
    _, rec = _arm_gateway_flow(vendor)
    state = rec["flow"].expected_state
    assert sessions.deliver_gateway_callback("wrong-" + state, code="c") is False
    assert sessions.deliver_gateway_callback("", code="c") is False
    assert sessions.deliver_gateway_callback(state, code="c") is True
    assert sessions.deliver_gateway_callback(state, code="c") is False
    assert rec["flow"].wait_worker_done(5)


def test_gateway_state_expires_with_the_session(vendor):
    result, rec = _arm_gateway_flow(vendor)
    rec["created_at"] = time.time() - sessions._SESSION_TTL_SECONDS - 1
    assert sessions.deliver_gateway_callback(rec["flow"].expected_state, code="c") is False
    stop(result)


def test_app_flow_state_is_not_reachable_through_gateway_route(vendor):
    set_public_url(PUBLIC)
    result = start()
    rec = sessions._sessions[result["session_id"]]
    assert sessions.deliver_gateway_callback(rec["flow"].expected_state, code="c") is False
    finish(result)


@pytest.fixture
def client():
    from hermes_cli.web_routers import mcp_oauth_callback
    app = FastAPI()
    app.include_router(mcp_oauth_callback.router)
    return TestClient(app)


def test_callback_route_completes_flow_and_opens_the_app(vendor, client, caplog):
    caplog.set_level(logging.DEBUG)
    result, rec = _arm_gateway_flow(vendor)
    state = rec["flow"].expected_state
    page = client.get(GATEWAY_CALLBACK_PATH, params={"code": "the-code", "state": state, "iss": "https://as.example.com"})
    assert page.status_code == 200
    assert APP_DONE_URL in page.text
    assert 'http-equiv="refresh"' in page.text
    assert "the-code" not in page.text and state not in page.text
    assert rec["flow"].wait_worker_done(5)
    assert sessions.poll_flow(result["session_id"], "srv")["status"] == "approved"
    replay = client.get(GATEWAY_CALLBACK_PATH, params={"code": "the-code", "state": state})
    assert replay.status_code == 400
    logged = "\n".join(r.getMessage() for r in caplog.records if not r.name.startswith("httpx"))
    assert "the-code" not in logged and state not in logged


def test_callback_route_reports_provider_denial_without_echo(vendor, client):
    result, rec = _arm_gateway_flow(vendor)
    state = rec["flow"].expected_state
    page = client.get(GATEWAY_CALLBACK_PATH, params={"state": state, "error": "access_denied<script>"})
    assert page.status_code == 200
    assert "access_denied" not in page.text and "script" not in page.text
    assert "not completed" in page.text
    assert rec["flow"].wait_worker_done(5)
    assert sessions.poll_flow(result["session_id"], "srv")["status"] == "error"


def test_callback_route_rejects_unknown_and_missing_state(client):
    assert client.get(GATEWAY_CALLBACK_PATH, params={"code": "c", "state": "nope"}).status_code == 400
    assert client.get(GATEWAY_CALLBACK_PATH, params={"code": "c"}).status_code == 400


def test_callback_path_is_public_at_the_gate_and_siblings_are_not():
    from hermes_cli.dashboard_auth.middleware import _path_is_public
    assert _path_is_public(GATEWAY_CALLBACK_PATH)
    assert not _path_is_public("/webapp/mcp-oauth/other")
    assert not _path_is_public("/webapp/mcp-oauth")
    assert not _path_is_public("/api/mcp/servers")


def test_access_log_redacts_callback_query():
    from gateway.chat_install_runtime import RedactInstallCallbackQuery
    record = logging.LogRecord("uvicorn.access", logging.INFO, "", 0, '%s - "%s %s HTTP/%s" %d',
                               ("1.2.3.4:5", "GET", GATEWAY_CALLBACK_PATH + "?code=SECRET&state=S", "1.1", 200), None)
    RedactInstallCallbackQuery().filter(record)
    assert "SECRET" not in record.getMessage()


def test_poll_unknown_session_has_no_redirect():
    assert "redirect" not in sessions.poll_flow("missing", "srv")
