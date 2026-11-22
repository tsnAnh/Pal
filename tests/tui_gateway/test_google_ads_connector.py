from __future__ import annotations

import json
import logging
import stat
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

import hermes_yaml as yaml
from gateway import oauth_client_setup as setup_mod
from tui_gateway import google_ads_connector as ads
from tui_gateway import server
from tui_gateway.ws_legacy_fallback import _connection_profile_home

CLIENT_SECRET = "fake-client-secret-do-not-use"
CLIENT_ID = "fake-client.apps.googleusercontent.com"
REFRESH = "fake-token-do-not-use-refresh"
ACCESS = "fake-token-do-not-use-access"
CODE = "fake-code-do-not-use"
PUBLIC_URL = "https://pal.example.ts.net"
MANAGER_ID = "1234567890"
TOOLS = [(name, "") for name in ads.READ_ONLY_TOOLS]


@pytest.fixture
def root(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    for name in ("work", "home"):
        (root / "profiles" / name).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.__init__",
                        lambda *_a, **_k: pytest.fail("reached the Nous Portal"))
    monkeypatch.setattr("gateway.chat_install_runtime.public_url_for", lambda _home: PUBLIC_URL)
    return root


@pytest.fixture
def work(root):
    return root / "profiles" / "work"


@pytest.fixture
def handshake(monkeypatch):
    state = {"tools": TOOLS, "configs": [], "restarts": 0}

    def probe(name, cfg, *_a, **_k):
        state["configs"].append((name, cfg))
        if isinstance(state["tools"], Exception):
            raise state["tools"]
        return state["tools"]

    monkeypatch.setattr("hermes_cli.mcp_config._probe_single_server", probe)
    monkeypatch.setattr(ads, "_restart_live", lambda: state.__setitem__("restarts", state["restarts"] + 1))
    return state


@pytest.fixture
def exchange(monkeypatch):
    replies = {"refresh": REFRESH, "scopes": []}

    def fake(token_url, data):
        replies["scopes"].append(data)
        return {"access_token": ACCESS, "refresh_token": replies["refresh"], "expires_in": 3600,
                "scope": ads_scope()}

    monkeypatch.setattr(setup_mod, "exchange_code", fake)
    return replies


def ads_scope():
    return "https://www.googleapis.com/auth/adwords"


@pytest.fixture
def web():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from hermes_cli.web_routers import google_install
    app = FastAPI()
    app.include_router(google_install.router)
    return TestClient(app)


def _call(method, profile="work", **params):
    return server._methods[method](1, {"profile": profile, **params})


def _ok(method, profile="work", **params):
    response = _call(method, profile, **params)
    assert "error" not in response, response
    return response["result"]


def _reason(response):
    return response["error"]["data"]["reason"]


def _row(slug, profile="work"):
    return {r["slug"]: r for r in _ok("connectors.catalog", profile)["connectors"]}[slug]


def _vault_item(value):
    return _ok("vault.add", kind="api_key", label="client", secret={"api_key": value})["id"]


def _save_client():
    return _ok("connectors.oauth_client.save", slug="google-workspace", client_id_item=_vault_item(CLIENT_ID),
               client_secret_item=_vault_item(CLIENT_SECRET))


def _sign_in(web):
    link = _ok("connectors.oauth_client.connect", slug="google-ads")["auth_url"]
    state = parse_qs(urlsplit(link).query)["state"][0]
    assert web.get("/webapp/google-install/callback", params={"code": CODE, "state": state}).status_code == 200
    return link


def _config_text(home):
    return (home / "config.yaml").read_text() if (home / "config.yaml").exists() else ""


def _everything(*parts):
    return json.dumps(parts, default=str)


def test_the_catalog_entry_runs_the_pinned_stdio_server_with_the_adwords_scope():
    from hermes_cli.pal_connectors import ConnectionMethod, load_pal_connectors

    entry = next(e for e in load_pal_connectors() if e.id == "google-ads")

    assert entry.method is ConnectionMethod.OAUTH_CLIENT and entry.mcp_url is None and entry.setup is None
    assert entry.scopes == (ads_scope(),)
    assert (entry.stdio.command, entry.stdio.args, entry.stdio.env) == ("uv", ("tool", "run", "google-ads-mcp==0.0.6"), ())


def test_the_mcp_catalog_manifest_matches_the_pal_recipe_and_allows_only_read_tools():
    from hermes_cli.mcp_catalog import get_entry
    from hermes_cli.pal_connectors import load_pal_connectors

    manifest = get_entry("google-ads")
    recipe = next(e for e in load_pal_connectors() if e.id == "google-ads").stdio

    assert manifest.transport.type == "stdio"
    assert (manifest.transport.command, tuple(manifest.transport.args)) == (recipe.command, recipe.args)
    assert manifest.auth.type == "none"
    assert manifest.tools.default_enabled == list(ads.READ_ONLY_TOOLS)


def test_the_tools_config_turns_on_customers_search_metadata_and_nothing_that_writes(work):
    ads.write_credentials(work, CLIENT_ID, CLIENT_SECRET, REFRESH)

    namespaces = yaml.safe_load(ads.tools_config_path(work).read_text())["namespaces"]

    assert namespaces == {"customers": True, "search": True, "metadata": True, "labels": False, "assets": False}
    assert set(ads.READ_ONLY_TOOLS) == {"customers_list_accessible_customers", "metadata_get_resource_metadata", "search_search"}
    assert not any(name.startswith(("labels_", "assets_")) for name in ads.READ_ONLY_TOOLS)


def test_the_server_env_points_at_the_files_and_carries_no_secret_developer_token_or_remote_mode(work):
    cfg = ads.server_config(work, MANAGER_ID)

    assert cfg["command"] == "uv" and cfg["args"] == ["tool", "run", "google-ads-mcp==0.0.6"]
    assert cfg["env"] == {
        "GOOGLE_APPLICATION_CREDENTIALS": str(ads.credentials_path(work)),
        "GOOGLE_ADS_MCP_TOOLS_CONFIG": str(ads.tools_config_path(work)),
        "GOOGLE_ADS_LOGIN_CUSTOMER_ID": MANAGER_ID,
    }
    assert cfg["tools"] == {"include": list(ads.READ_ONLY_TOOLS)} and cfg["connect_timeout"] == ads.FIRST_START_TIMEOUT_SECONDS
    assert "GOOGLE_ADS_LOGIN_CUSTOMER_ID" not in ads.server_config(work, None)["env"]


def test_sign_in_asks_only_the_adwords_scope_and_writes_a_private_root_credentials_file_shared_with_other_profiles(root, exchange, web, caplog):
    caplog.set_level(logging.DEBUG)
    assert _row("google-ads")["status"] == "needs_setup"
    _save_client()
    assert _row("google-ads")["status"] == "not_connected"

    link = _sign_in(web)

    query = parse_qs(urlsplit(link).query)
    assert query["scope"] == [ads_scope()] and "include_granted_scopes" not in query and query["access_type"] == ["offline"]
    assert query["redirect_uri"] == [PUBLIC_URL + "/webapp/google-install/callback"]
    assert _row("google-ads")["status"] == "connected"
    assert _row("google-ads", "home")["status"] == "connected"
    assert _row("google-workspace")["status"] == "not_connected"
    path = ads.credentials_path(root)
    assert json.loads(path.read_text()) == {
        "type": "authorized_user", "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET, "refresh_token": REFRESH}
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert not (root / "google_token.json").exists()
    logs = "\n".join(r.getMessage() for r in caplog.records if not r.name.startswith("httpx"))
    for leaked in (REFRESH, ACCESS, CLIENT_SECRET, CODE):
        assert leaked not in logs


def test_a_new_sign_in_rewrites_the_credentials_file_with_the_new_refresh_token(root, exchange, web):
    _save_client()
    _sign_in(web)
    exchange["refresh"] = "fake-token-do-not-use-second"

    _sign_in(web)

    assert json.loads(ads.credentials_path(root).read_text())["refresh_token"] == "fake-token-do-not-use-second"
    assert stat.S_IMODE(ads.credentials_path(root).stat().st_mode) == 0o600


def test_status_walks_from_needs_setup_to_configured(root, exchange, web, handshake):
    assert _ok("connectors.google_ads.status") == {"state": "needs_setup", "configured": False, "login_customer_id": None}
    _save_client()
    assert _ok("connectors.google_ads.status")["state"] == "needs_sign_in"
    _sign_in(web)
    assert _ok("connectors.google_ads.status") == {"state": "signed_in", "configured": False, "login_customer_id": None}

    _ok("connectors.google_ads.save", login_customer_id=MANAGER_ID)

    assert _ok("connectors.google_ads.status") == {"state": "signed_in", "configured": True, "login_customer_id": MANAGER_ID}


def test_save_commits_the_read_only_server_and_reports_the_tool_count(root, exchange, web, handshake):
    _save_client()
    _sign_in(web)

    result = _ok("connectors.google_ads.save", login_customer_id="")

    assert result == {"tools": 3, "login_customer_id": None}
    name, cfg = handshake["configs"][-1]
    assert name == "google-ads" and cfg["env"]["GOOGLE_APPLICATION_CREDENTIALS"] == str(ads.credentials_path(root))
    assert "GOOGLE_ADS_LOGIN_CUSTOMER_ID" not in cfg["env"]
    assert handshake["restarts"] == 0
    saved = yaml.safe_load(_config_text(root))["mcp_servers"]["google-ads"]
    assert saved["tools"] == {"include": list(ads.READ_ONLY_TOOLS)}
    assert REFRESH not in _config_text(root) and CLIENT_SECRET not in _config_text(root)
    _ok("connectors.google_ads.save", login_customer_id=MANAGER_ID)
    assert handshake["restarts"] == 1


@pytest.mark.parametrize("bad", ["12a4", "123 456", "123-456-7890", "-1", "１２３", "1" * 21])
def test_a_manager_id_that_is_not_digits_only_is_refused_before_anything_is_written(root, exchange, web, handshake, bad):
    _save_client()
    _sign_in(web)
    ads.credentials_path(root).unlink()

    response = _call("connectors.google_ads.save", login_customer_id=bad)

    assert response["error"]["code"] == 4000 and _reason(response) == "INVALID_PARAMS"
    assert handshake["configs"] == [] and not ads.credentials_path(root).exists()
    assert "google-ads" not in _config_text(root)


def test_save_without_a_sign_in_or_client_asks_for_it(root, handshake):
    assert _reason(_call("connectors.google_ads.save")) == "NEEDS_SETUP"
    _save_client()
    response = _call("connectors.google_ads.save")
    assert _reason(response) == "NEEDS_SETUP" and handshake["configs"] == []


@pytest.mark.parametrize("probed", [
    TOOLS + [("labels_manage_labels", "")],
    TOOLS + [("assets_create_asset", "")],
    [],
    RuntimeError("boom " + REFRESH),
])
def test_a_handshake_that_fails_or_shows_a_tool_outside_the_read_list_is_rolled_back(
        root, exchange, web, handshake, probed, caplog):
    caplog.set_level(logging.DEBUG)
    _save_client()
    _sign_in(web)
    handshake["tools"] = probed

    response = _call("connectors.google_ads.save", login_customer_id=MANAGER_ID)

    assert response["error"]["code"] == 5034 and _reason(response) == "CONNECT_FAILED"
    assert "google-ads" not in _config_text(root)
    assert REFRESH not in caplog.text and REFRESH not in json.dumps(response)


def test_every_google_ads_rpc_is_owner_only(root, exchange, web, handshake):
    _save_client()
    _sign_in(web)
    token = _connection_profile_home.set(str(root / "profiles" / "home"))
    try:
        for method in ("connectors.google_ads.status", "connectors.google_ads.save", "connectors.google_ads.verify"):
            response = _call(method, "home")
            assert response["error"]["code"] == 4030 and _reason(response) == "NOT_OWNER", method
    finally:
        _connection_profile_home.reset(token)
    assert handshake["configs"] == []


def test_sign_out_deletes_the_file_the_server_and_the_ads_sign_in_but_keeps_the_google_client(
        root, exchange, web, handshake):
    _save_client()
    _sign_in(web)
    _ok("connectors.google_ads.save", login_customer_id=MANAGER_ID)
    store = setup_mod.build_store()
    _, item = store.connection("google-ads", setup_mod.profile_key(root))

    removed = _ok("connectors.oauth_client.remove", slug="google-ads")

    assert removed["removed"] is True
    assert not ads.credentials_path(root).exists() and not ads.connector_dir(root).exists()
    assert "google-ads" not in _config_text(root)
    assert store.connection("google-ads", setup_mod.profile_key(root)) is None
    with pytest.raises(Exception):
        setup_mod.vault_for(root).resolve_secret(item)
    assert _ok("connectors.oauth_client.setup", slug="google-ads")["configured"] is True
    assert _row("google-ads")["status"] == "not_connected"


def test_removing_the_workspace_sign_in_leaves_the_ads_sign_in_alone(root, exchange, web):
    _save_client()
    _sign_in(web)

    _ok("connectors.oauth_client.remove", slug="google-workspace")

    assert ads.credentials_path(root).exists() and _row("google-ads")["status"] == "connected"


@pytest.fixture
def google(monkeypatch):
    state = {"token": {"status": 200, "json": {"access_token": ACCESS, "expires_in": 3600}},
             "ads": {"status": 200, "json": {"resourceNames": ["customers/1", "customers/2"]}}, "seen": [], "raise": None}

    def post(url, **kwargs):
        state["seen"].append(("post", url))
        if state["raise"]:
            raise state["raise"]
        return httpx.Response(state["token"]["status"], json=state["token"]["json"])

    def get(url, **kwargs):
        state["seen"].append(("get", url, kwargs["headers"]["Authorization"]))
        if state["raise"]:
            raise state["raise"]
        return httpx.Response(state["ads"]["status"], json=state["ads"]["json"])

    monkeypatch.setattr(ads.httpx, "post", post)
    monkeypatch.setattr(ads.httpx, "get", get)
    return state


def _signed_in(web):
    _save_client()
    _sign_in(web)


def test_verify_counts_the_accounts_the_sign_in_can_reach(root, exchange, web, google, caplog):
    caplog.set_level(logging.DEBUG)
    _signed_in(web)

    result = _ok("connectors.google_ads.verify")

    assert result == {"check": "ready", "accounts": 2}
    assert google["seen"][-1] == ("get", ads.ACCESSIBLE_CUSTOMERS_URL, f"Bearer {ACCESS}")
    assert ACCESS not in caplog.text and ACCESS not in json.dumps(result)


@pytest.mark.parametrize("body", [
    {"error": {"code": 403, "status": "PERMISSION_DENIED", "details": [{"errors": [
        {"errorCode": {"authorizationError": "CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION"}, "message": "x"}]}]}},
    {"error": {"code": 403, "details": [{"errors": [{"errorCode": {"authorizationError": "DEVELOPER_TOKEN_NOT_APPROVED"}}]}]}},
])
def test_google_not_approving_the_cloud_project_reads_as_apply_for_explorer_access(root, exchange, web, google, body):
    _signed_in(web)
    google["ads"] = {"status": 403, "json": body}

    assert _ok("connectors.google_ads.verify") == {"check": "explorer_access_needed", "accounts": None}
    assert _row("google-ads")["status"] == "connected"


def test_an_expired_refresh_token_marks_the_row_needs_reconnect(root, exchange, web, google):
    _signed_in(web)
    google["token"] = {"status": 400, "json": {"error": "invalid_grant"}}

    assert _ok("connectors.google_ads.verify") == {"check": "needs_reauth", "accounts": None}
    assert _row("google-ads")["status"] == "needs_reconnect"
    assert _ok("connectors.google_ads.status")["state"] == "needs_reconnect"


def test_a_rejected_access_token_reads_as_needs_reauth(root, exchange, web, google):
    _signed_in(web)
    google["ads"] = {"status": 401, "json": {"error": {"code": 401}}}

    assert _ok("connectors.google_ads.verify")["check"] == "needs_reauth"
    assert _row("google-ads")["status"] == "needs_reconnect"


@pytest.mark.parametrize("failure", ["offline", "server_error", "forbidden_other", "token_server_error"])
def test_everything_else_is_unreachable_and_leaves_the_sign_in_alone(root, exchange, web, google, failure):
    _signed_in(web)
    if failure == "offline":
        google["raise"] = httpx.ConnectError("down")
    elif failure == "server_error":
        google["ads"] = {"status": 500, "json": {}}
    elif failure == "forbidden_other":
        google["ads"] = {"status": 403, "json": {"error": {"message": "other"}}}
    else:
        google["token"] = {"status": 500, "json": {}}

    assert _ok("connectors.google_ads.verify") == {"check": "unreachable", "accounts": None}
    assert _row("google-ads")["status"] == "connected"


def test_no_rpc_answer_carries_a_token_or_the_client_secret(root, exchange, web, google, handshake, caplog):
    caplog.set_level(logging.DEBUG)
    _save_client()
    _sign_in(web)
    answers = [_ok("connectors.google_ads.status"), _ok("connectors.google_ads.save", login_customer_id=MANAGER_ID),
               _ok("connectors.google_ads.verify"), _row("google-ads"), _ok("connectors.oauth_client.setup", slug="google-ads")]
    google["token"] = {"status": 400, "json": {"error": "invalid_grant", "error_description": REFRESH}}
    answers.append(_ok("connectors.google_ads.verify"))

    gateway_logs = "\n".join(r.getMessage() for r in caplog.records if not r.name.startswith("httpx"))
    blob = _everything(answers) + gateway_logs
    for secret in (REFRESH, ACCESS, CLIENT_SECRET, CODE):
        assert secret not in blob
