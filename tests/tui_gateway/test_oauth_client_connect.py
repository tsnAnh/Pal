from __future__ import annotations

import json
import logging
from urllib.parse import parse_qs, urlsplit

import pytest

import hermes_yaml as yaml
from gateway import oauth_client_setup as setup_mod
from tui_gateway import server

OWNER_SECRET = "fake-token-do-not-use"
GOOGLE_CLIENT_ID = "fake-client.apps.googleusercontent.com"
FIGMA_CLIENT_ID = "fake-figma-client"
PUBLIC_URL = "https://pal.example.ts.net"


@pytest.fixture
def root(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    for name in ("work", "home"):
        (root / "profiles" / name).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.__init__",
                        lambda *_a, **_k: pytest.fail("reached the Nous Portal"))
    return root


@pytest.fixture
def public_url(monkeypatch):
    holder = {"url": PUBLIC_URL}
    monkeypatch.setattr("gateway.chat_install_runtime.public_url_for", lambda _home: holder["url"])
    return holder


def _call(method, profile, **params):
    return server._methods[method](1, {"profile": profile, **params})


def _ok(method, profile="work", **params):
    response = _call(method, profile, **params)
    assert "error" not in response, response
    return response["result"]


def _status(slug, profile="work"):
    return {row["slug"]: row for row in _ok("connectors.catalog", profile)["connectors"]}[slug]["status"]


def _vault_item(profile, value):
    return _ok("vault.add", profile, kind="api_key", label="client", secret={"api_key": value})["id"]


def _save(slug, client_id, profile="work"):
    return _ok("connectors.oauth_client.save", profile, slug=slug, client_id_item=_vault_item(profile, client_id),
               client_secret_item=_vault_item(profile, OWNER_SECRET))


def _wire_and_logs(caplog, *results):
    return json.dumps(results) + caplog.text


def test_setup_is_saved_once_and_every_profile_sees_it(root, public_url, caplog):
    caplog.set_level(logging.DEBUG)
    assert _status("google-workspace") == "needs_setup"
    before = _ok("connectors.oauth_client.setup", slug="google-workspace")
    assert before["configured"] is False
    assert before["redirect_url"] == PUBLIC_URL + "/webapp/google-install/callback"

    saved = _save("google-workspace", GOOGLE_CLIENT_ID)

    assert saved["configured"] is True
    assert _status("google-workspace") == "not_connected"
    assert _status("google-workspace", "home") == "not_connected"
    assert _ok("connectors.oauth_client.setup", "home", slug="google-workspace")["configured"] is True
    assert OWNER_SECRET not in _wire_and_logs(caplog, saved, before)


def test_google_without_a_public_https_address_returns_the_guided_step(root, public_url):
    _save("google-workspace", GOOGLE_CLIENT_ID)
    public_url["url"] = "http://192.168.1.4:9119"

    response = _call("connectors.oauth_client.connect", "work", slug="google-workspace")

    assert response["error"]["data"]["reason"] == "NEEDS_PUBLIC_URL"
    assert _ok("connectors.oauth_client.setup", slug="google-workspace")["redirect_url"] is None


def _begin_google(profile="work"):
    link = _ok("connectors.oauth_client.connect", profile, slug="google-workspace")["auth_url"]
    query = parse_qs(urlsplit(link).query)
    assert query["redirect_uri"] == [PUBLIC_URL + "/webapp/google-install/callback"]
    assert query["client_id"] == [GOOGLE_CLIENT_ID]
    return query["state"][0]


@pytest.fixture
def exchange(monkeypatch):
    calls = []

    def fake(token_url, data):
        calls.append(data)
        return {"access_token": "fake-token-do-not-use-access", "refresh_token": "fake-token-do-not-use-refresh",
                "expires_in": 3600, "scope": "openid email"}

    monkeypatch.setattr(setup_mod, "exchange_code", fake)
    return calls


def _callback(client, **query):
    return client.get("/webapp/google-install/callback", params=query)


@pytest.fixture
def web():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from hermes_cli.web_routers import google_install
    app = FastAPI()
    app.include_router(google_install.router)
    return TestClient(app)


def test_google_redirect_accepts_a_state_once_and_stores_the_token_in_the_vault(root, public_url, exchange, web, caplog):
    caplog.set_level(logging.DEBUG)
    _save("google-workspace", GOOGLE_CLIENT_ID)
    state = _begin_google()

    first = _callback(web, code="fake-code-do-not-use", state=state)
    replay = _callback(web, code="fake-code-do-not-use", state=state)

    assert first.status_code == 200 and "Return to Pal" in first.text
    assert replay.status_code == 400
    assert len(exchange) == 1 and exchange[0]["client_secret"] == OWNER_SECRET
    assert _status("google-workspace") == "connected"
    assert _status("google-workspace", "home") == "not_connected"
    store = setup_mod.build_store()
    _, item = store.connection("google-workspace", setup_mod.profile_key(root / "profiles" / "work"))
    vault = setup_mod.vault_for(root / "profiles" / "work")
    assert vault.resolve_secret(item)["api_key"] == "fake-token-do-not-use-refresh"
    gateway_logs = "\n".join(r.getMessage() for r in caplog.records if not r.name.startswith("httpx"))
    for leaked in (state, "fake-code-do-not-use", OWNER_SECRET):
        assert leaked not in gateway_logs
        assert leaked not in first.text


def test_the_access_log_drops_the_google_callback_query():
    from gateway.chat_install_runtime import RedactInstallCallbackQuery
    record = logging.LogRecord("uvicorn.access", logging.INFO, "", 0, '%s - "%s %s"', (
        "1.2.3.4", "GET", "/webapp/google-install/callback?code=fake-code-do-not-use&state=s"), None)

    RedactInstallCallbackQuery().filter(record)

    assert "fake-code-do-not-use" not in record.getMessage()


def test_a_forged_state_is_rejected_without_an_exchange(root, public_url, exchange, web):
    _save("google-workspace", GOOGLE_CLIENT_ID)
    _begin_google()

    assert _callback(web, code="fake-code-do-not-use", state="forged").status_code == 400
    assert exchange == []
    assert _status("google-workspace") == "not_connected"


def test_remove_deletes_the_profile_sign_in_and_keeps_the_owner_client(root, public_url, exchange, web):
    _save("google-workspace", GOOGLE_CLIENT_ID)
    _callback(web, code="fake-code-do-not-use", state=_begin_google())
    token_file = root / "profiles" / "work" / "google_token.json"
    assert token_file.exists()

    _ok("connectors.oauth_client.remove", slug="google-workspace")

    assert not token_file.exists()
    assert _status("google-workspace") == "not_connected"
    assert _ok("connectors.oauth_client.setup", slug="google-workspace")["configured"] is True


def test_figma_connects_through_the_mcp_path_with_the_owner_client(root, public_url, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    started = {}

    def fake_start(home, name, cfg, client_redirect_uri=None):
        started.update(name=name, cfg=cfg)
        return {"session_id": "s1", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    def fake_gateway(home, name, cfg, redirect_uri):
        started.update(name=name, cfg=cfg, redirect_uri=redirect_uri)
        return {"session_id": "s1", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_gateway_flow", fake_gateway)
    assert _status("figma") == "needs_setup"
    _save("figma", FIGMA_CLIENT_ID)
    assert _status("figma") == "not_connected"

    result = _ok("connectors.oauth_client.connect", slug="figma")

    assert result["session_id"] == "s1"
    assert started["cfg"]["oauth"]["client_id"] == FIGMA_CLIENT_ID
    assert started["redirect_uri"] == PUBLIC_URL + "/webapp/mcp-oauth/callback"
    assert started["cfg"]["oauth"]["redirect_uri"] == started["redirect_uri"]
    assert "redirect_port" not in started["cfg"]["oauth"]
    config = (root / "profiles" / "work" / "config.yaml").read_text()
    assert OWNER_SECRET not in config
    assert yaml.safe_load(config)["mcp_servers"]["figma"]["oauth"]["client_id"] == FIGMA_CLIENT_ID
    assert _status("figma") == "connected"
    assert OWNER_SECRET not in _wire_and_logs(caplog, result)

    _ok("connectors.oauth_client.remove", slug="figma")
    assert _status("figma") == "not_connected"
    assert _ok("connectors.oauth_client.setup", slug="figma")["configured"] is True


def test_figma_keeps_the_registered_loopback_without_a_public_https_address(root, public_url, monkeypatch):
    started = {}

    def fake_start(home, name, cfg, client_redirect_uri=None):
        started.update(cfg=cfg)
        return {"session_id": "s1", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    public_url["url"] = None
    _save("figma", FIGMA_CLIENT_ID)
    assert _ok("connectors.oauth_client.setup", slug="figma")["redirect_url"] == "http://localhost:27890/callback"
    _ok("connectors.oauth_client.connect", slug="figma")
    assert started["cfg"]["oauth"]["redirect_port"] == 27890 and "redirect_uri" not in started["cfg"]["oauth"]


def _vault_ids(profile="work"):
    return {item["id"] for item in _ok("vault.list", profile)["items"]}


def test_remove_client_deletes_the_saved_client_and_its_vault_items(root, public_url):
    _save("figma", FIGMA_CLIENT_ID)
    record = setup_mod.build_store().client("figma")
    items = {record.client_id_item, record.client_secret_item}
    assert items <= _vault_ids()

    result = _ok("connectors.oauth_client.remove", slug="figma", remove_client=True)

    assert result["removed"] is True
    assert _ok("connectors.oauth_client.setup", slug="figma")["configured"] is False
    assert _status("figma") == "needs_setup"
    assert not items & _vault_ids()
    assert _ok("connectors.oauth_client.remove", slug="figma", remove_client=True)["removed"] is False


def test_remove_client_drops_the_google_sign_in_with_the_client(root, public_url, exchange, web):
    _save("google-workspace", GOOGLE_CLIENT_ID)
    _callback(web, code="fake-code-do-not-use", state=_begin_google())
    assert (root / "profiles" / "work" / "google_token.json").exists()

    _ok("connectors.oauth_client.remove", slug="google-workspace", remove_client=True)

    assert not (root / "profiles" / "work" / "google_token.json").exists()
    assert _status("google-workspace") == "needs_setup"


def test_remove_client_is_owner_only_and_the_default_keeps_the_client(root, public_url):
    from tui_gateway.ws_legacy_fallback import _connection_profile_home
    _save("figma", FIGMA_CLIENT_ID)
    token = _connection_profile_home.set(str(root / "profiles" / "home"))
    try:
        response = _call("connectors.oauth_client.remove", "work", slug="figma", remove_client=True)
        assert response["error"]["data"]["reason"] == "NOT_OWNER"
        assert "error" not in _call("connectors.oauth_client.remove", "work", slug="figma")
    finally:
        _connection_profile_home.reset(token)
    assert _ok("connectors.oauth_client.setup", slug="figma")["configured"] is True


@pytest.mark.parametrize("slug", ["figma", "dropbox", "canva"])
def test_mcp_clients_redirect_to_the_gateway_callback_and_fall_back_to_loopback(root, public_url, monkeypatch, slug):
    started = {}

    def fake_start(home, name, cfg, client_redirect_uri=None):
        started.update(via="loopback", redirect=cfg["oauth"].get("redirect_uri"))
        return {"session_id": "s1", "auth_url": "https://vendor.example/oauth", "flow": "pkce"}

    def fake_gateway(home, name, cfg, redirect_uri):
        started.update(via="gateway", redirect=redirect_uri, configured=cfg["oauth"]["redirect_uri"])
        return {"session_id": "s1", "auth_url": "https://vendor.example/oauth", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_gateway_flow", fake_gateway)
    _save(slug, FIGMA_CLIENT_ID)

    callback = PUBLIC_URL + "/webapp/mcp-oauth/callback"
    assert _ok("connectors.oauth_client.setup", slug=slug)["redirect_url"] == callback
    _ok("connectors.oauth_client.connect", slug=slug)
    assert started == {"via": "gateway", "redirect": callback, "configured": callback}

    public_url["url"] = None
    assert _ok("connectors.oauth_client.setup", slug=slug)["redirect_url"] == setup_mod.MCP_REDIRECT_URL
    _ok("connectors.oauth_client.connect", slug=slug)
    assert started["via"] == "loopback"
