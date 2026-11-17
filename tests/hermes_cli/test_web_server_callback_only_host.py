import asyncio

import pytest

from gateway.webapp_listener import WebappSettings
from hermes_cli import web_server_boundary as boundary
from hermes_cli.dashboard_auth.public_paths import OAUTH_CALLBACK_PATHS
from hermes_cli.web_routers.mcp_oauth_callback import REJECTED_MESSAGE
from hermes_cli import web_server
from hermes_cli.web_server import app

PUBLIC = "pal.example.com"
REFUSED = "Invalid Host header"


def _call(path, host, raw_path=None, token=False):
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "GET", "scheme": "https",
             "path": path, "raw_path": (raw_path or path).encode(), "query_string": b"", "root_path": "",
             "headers": [(b"host", host.encode())] + ([(b"authorization", f"Bearer {web_server._SESSION_TOKEN}".encode())] if token else []), "client": ("127.0.0.1", 1), "server": ("127.0.0.1", 1), "app": app}
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    asyncio.run(app(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    return status, b"".join(m.get("body", b"") for m in sent).decode()


@pytest.fixture
def gateway(monkeypatch):
    settings = {"value": WebappSettings(public_url=f"https://{PUBLIC}")}
    monkeypatch.setattr("gateway.webapp_listener.webapp_settings", lambda home: settings["value"])
    monkeypatch.setattr(boundary, "_callback_hosts_cache", (-100.0, frozenset()))
    monkeypatch.setattr(app.state, "bound_host", "127.0.0.1", raising=False)
    monkeypatch.setattr(app.state, "trusted_public_hosts", frozenset(), raising=False)
    monkeypatch.setattr(app.state, "gateway_runner", object(), raising=False)
    return settings


def _answered(status, body):
    return status == 400 and REJECTED_MESSAGE in body


def _refused(status, body):
    return status == 400 and REFUSED in body


@pytest.mark.parametrize("path", OAUTH_CALLBACK_PATHS)
def test_each_callback_route_answers_on_the_public_host(gateway, path):
    assert not _refused(*_call(path, PUBLIC))
    assert not _refused(*_call(path, f"{PUBLIC}:443"))


def test_the_mcp_callback_gives_its_own_rejection_for_an_unissued_state(gateway):
    assert _answered(*_call("/webapp/mcp-oauth/callback", PUBLIC))


@pytest.mark.parametrize("path", [
    "/", "/api/status", "/api/sessions", "/webapp", "/webapp/", "/webapp/gateway-connections/oauth/callback",
    "/api/mcp/oauth/callback/x", "/assets/app.js", "/auth/login"])
def test_every_other_path_on_the_public_host_is_refused(gateway, path):
    assert _refused(*_call(path, PUBLIC, token=True))
    assert _call(path, PUBLIC)[0] in (400, 401, 404)


@pytest.mark.parametrize("path, raw", [
    ("/webapp/mcp-oauth/callback/", None),
    ("/webapp/mcp-oauth/callback/../x", None),
    ("/webapp/mcp-oauth/callback/x", None),
    ("/webapp/mcp-oauth/callbackx", None),
    ("//webapp/mcp-oauth/callback", None),
    ("/webapp//mcp-oauth/callback", None),
    ("/webapp/mcp-oauth/callback", "/webapp%2Fmcp-oauth/callback"),
    ("/webapp/mcp-oauth/callback", "/%77ebapp/mcp-oauth/callback"),
    ("/webapp/mcp-oauth/callback", "/webapp/mcp-oauth/callback%2F.."),
    ("/WEBAPP/mcp-oauth/callback", None),
])
def test_path_tricks_on_the_public_host_are_refused(gateway, path, raw):
    assert _refused(*_call(path, PUBLIC, raw))


@pytest.mark.parametrize("host", [
    "evil.example.com", f"{PUBLIC}.evil.example", f"evil.{PUBLIC}", f"{PUBLIC}@evil.example", "", f"{PUBLIC}/x",
    f"{PUBLIC}:99999x"])
def test_another_host_with_a_callback_path_is_refused(gateway, host):
    assert _refused(*_call("/webapp/mcp-oauth/callback", host))


def test_loopback_still_reaches_everything(gateway):
    assert not _refused(*_call("/api/health", "127.0.0.1"))
    assert not _refused(*_call("/webapp/mcp-oauth/callback", "localhost"))


def test_no_public_address_changes_nothing(gateway):
    gateway["value"] = WebappSettings()
    assert _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))


def test_the_webapp_on_keeps_its_own_trusted_hosts_and_adds_no_callback_mode(gateway):
    gateway["value"] = WebappSettings(enabled=True, public_url=f"https://{PUBLIC}")
    assert _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))
    app.state.trusted_public_hosts = frozenset({PUBLIC})
    assert not _refused(*_call("/api/health", PUBLIC))


def test_a_listener_that_is_not_the_gateways_never_opens_callback_mode(gateway, monkeypatch):
    monkeypatch.setattr(app.state, "gateway_runner", None)
    assert _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))


def test_a_changed_address_applies_after_the_cache_expires(gateway, monkeypatch):
    assert not _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))
    gateway["value"] = WebappSettings(public_url="https://other.example.com")
    assert not _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))
    monkeypatch.setattr(boundary, "_callback_hosts_cache", (-100.0, frozenset()))
    assert _refused(*_call("/webapp/mcp-oauth/callback", PUBLIC))
    assert not _refused(*_call("/webapp/mcp-oauth/callback", "other.example.com"))


def test_the_shared_callback_list_matches_the_routers():
    from gateway.oauth_client_setup import GOOGLE_REDIRECT_PATH
    from tools.connectors.mcp_oauth_redirect import GATEWAY_CALLBACK_PATH
    from tui_gateway.chat_install import REDIRECT_PATH
    assert set(OAUTH_CALLBACK_PATHS) == {REDIRECT_PATH, GATEWAY_CALLBACK_PATH, GOOGLE_REDIRECT_PATH}
