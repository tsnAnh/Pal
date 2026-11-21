import json
import logging

import httpx
import pytest

from gateway import connector_setup_checks as checks
from hermes_cli.pal_connectors import load_pal_connectors
from tui_gateway import server

SECRET = "fake-secret-do-not-use"
PUBLIC_URL = "https://pal.example.ts.net"
GOOGLE_ID = "fake.apps.googleusercontent.com"


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


@pytest.fixture
def provider(monkeypatch):
    holder = {"handler": lambda _r: httpx.Response(500), "seen": []}

    def handle(request):
        holder["seen"].append(request)
        return holder["handler"](request)

    monkeypatch.setattr(checks, "default_transport", httpx.MockTransport(handle))
    return holder


def _call(method, profile="work", **params):
    return server._methods[method](1, {"profile": profile, **params})


def _ok(method, profile="work", **params):
    response = _call(method, profile, **params)
    assert "error" not in response, response
    return response["result"]


def _row(slug, profile="work"):
    return {r["slug"]: r for r in _ok("connectors.catalog", profile)["connectors"]}[slug]


def _item(value, profile="work"):
    return _ok("vault.add", profile, kind="api_key", label="pasted", secret={"api_key": value})["id"]


def test_catalog_row_serializes_the_guide_with_resolved_copies(root, public_url):
    row = _row("google-workspace")
    steps = {s["id"]: s for s in row["setup_guide"]["steps"]}
    assert [s["id"] for s in row["setup_guide"]["steps"]] == ["address", "console", "apis", "client"]
    assert steps["console"]["copies"] == [{"label": "Redirect URI", "value": PUBLIC_URL + "/webapp/google-install/callback"}]
    assert steps["client"]["check"] == "google_client"
    assert steps["client"]["fields"][0]["suffix"] == ".apps.googleusercontent.com"
    assert steps["client"]["fields"][1]["secret"] is True
    assert {"slug", "name", "category", "icon", "method", "verified", "mcp_url", "status", "notes"} <= set(row)


def test_unresolvable_copy_is_omitted_without_a_public_address(root, public_url):
    public_url["url"] = None
    steps = {s["id"]: s for s in _row("google-workspace")["setup_guide"]["steps"]}
    assert steps["console"]["copies"] == []
    assert _row("google-workspace")["setup_progress"] == {"step_id": "address", "saved": []}


def test_entries_without_a_guide_keep_the_old_shape(root, public_url):
    row = _row("slack")
    assert row["setup_guide"] is None and row["setup_progress"] is None


def test_progress_resumes_per_instance(root, public_url, provider):
    provider["handler"] = lambda _r: httpx.Response(400, json={"error": "invalid_grant"})
    assert _row("google-workspace")["setup_progress"] == {"step_id": "console", "saved": []}
    assert _row("figma")["setup_progress"] == {"step_id": "app", "saved": []}
    assert _row("github")["setup_progress"] == {"step_id": "token_page", "saved": []}

    _ok("connectors.oauth_client.save", slug="google-workspace", client_id_item=_item(GOOGLE_ID),
        client_secret_item=_item(SECRET))
    assert _row("google-workspace")["setup_progress"] == {"step_id": "client", "saved": ["client_id", "client_secret"]}
    assert _row("google-workspace", "home")["setup_progress"]["saved"] == ["client_id", "client_secret"]
    assert _row("figma")["setup_progress"]["step_id"] == "app"

    public_url["url"] = None
    assert _row("google-workspace")["setup_progress"]["step_id"] == "address"


def test_check_accepts_and_the_secret_never_leaks(root, public_url, provider, caplog):
    caplog.set_level(logging.DEBUG)
    provider["handler"] = lambda _r: httpx.Response(400, json={"error": "invalid_grant"})

    result = _ok("connectors.setup.check", slug="google-workspace",
                 values={"client_id": _item(GOOGLE_ID), "client_secret": _item(SECRET)})

    assert result == {"slug": "google-workspace", "ok": True, "reason": None, "message": None, "account": None}
    body = provider["seen"][0].content.decode()
    assert SECRET in body and PUBLIC_URL.replace(":", "%3A").replace("/", "%2F") in body
    assert SECRET not in json.dumps(result) + caplog.text


def test_check_rejection_is_a_result_not_an_rpc_error(root, public_url, provider):
    provider["handler"] = lambda _r: httpx.Response(401, json={})

    result = _ok("connectors.setup.check", slug="canva",
                 values={"client_id": _item("OC-fake"), "client_secret": _item(SECRET)})

    assert result["ok"] is False and result["reason"] == "INVALID_CLIENT" and result["message"]


def test_github_check_returns_the_account(root, public_url, provider):
    provider["handler"] = lambda _r: httpx.Response(200, json={"login": "octo"})
    result = _ok("connectors.setup.check", slug="github", values={"token": _item(SECRET)})
    assert result["ok"] is True and result["account"] == "octo"


def test_network_failure_reports_check_unavailable(root, public_url, provider, caplog):
    caplog.set_level(logging.DEBUG)

    def boom(request):
        raise httpx.ConnectTimeout(SECRET, request=request)

    provider["handler"] = boom
    result = _ok("connectors.setup.check", slug="github", values={"token": _item(SECRET)})
    assert result["ok"] is False and result["reason"] == "CHECK_UNAVAILABLE"
    assert SECRET not in json.dumps(result) + caplog.text


def test_check_rpc_errors(root, public_url, provider):
    assert _call("connectors.setup.check", slug="slack", values={})["error"]["data"]["reason"] == "CONNECTOR_NOT_FOUND"
    assert _call("connectors.setup.check", slug="github", values={"token": "missing"})["error"]["data"]["reason"] == "CLIENT_UNREADABLE"
    assert _call("connectors.setup.check", slug="github", values={})["error"]["data"]["reason"] == "INVALID_PARAMS"
    assert provider["seen"] == []


def test_figma_connects_through_the_preregistered_mcp_path(root, public_url, monkeypatch):
    started = {}

    def fake_start(home, name, cfg, client_redirect_uri=None):
        started.update(name=name, cfg=cfg)
        return {"session_id": "s1", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    def fake_gateway(home, name, cfg, redirect_uri):
        started.update(name=name, cfg=cfg, redirect_uri=redirect_uri)
        return {"session_id": "s1", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_gateway_flow", fake_gateway)
    assert _row("figma")["status"] == "needs_setup"
    saved = _ok("connectors.oauth_client.save", slug="figma", client_id_item=_item("1.2"),
                client_secret_item=_item(SECRET))
    assert saved["redirect_url"] == PUBLIC_URL + "/webapp/mcp-oauth/callback"
    assert _row("figma")["setup_progress"] == {"step_id": "client", "saved": ["client_id", "client_secret"]}

    assert _ok("connectors.oauth_client.connect", slug="figma")["session_id"] == "s1"
    assert started["name"] == "figma@default" and started["cfg"]["url"] == "https://mcp.figma.com/mcp"
    assert started["cfg"]["oauth"]["client_id"] == "1.2" and started["redirect_uri"] == saved["redirect_url"]
    config = (root / "profiles" / "work" / "config.yaml").read_text()
    assert SECRET not in config and "FIGMA_CLIENT_SECRET" in config


def test_every_guide_check_has_its_fields_declared():
    for entry in load_pal_connectors():
        for step in (entry.setup.steps if entry.setup else ()):
            if step.check:
                assert tuple(f.id for f in step.fields) == checks.FIELDS[step.check]


@pytest.mark.parametrize("slug", ["figma", "dropbox"])
def test_mcp_guides_copy_the_gateway_redirect_and_skip_the_test_call(root, public_url, provider, slug):
    steps = {s["id"]: s for s in _row(slug)["setup_guide"]["steps"]}
    copies = {c["label"]: c["value"] for c in steps["app"]["copies"]}
    assert copies[next(k for k in copies if k.startswith("Redirect"))] == PUBLIC_URL + "/webapp/mcp-oauth/callback"
    assert "Scopes" in copies
    assert steps["client"]["check"] is None
    assert [f["id"] for f in steps["client"]["fields"]] == ["client_id", "client_secret"]
    assert _call("connectors.setup.check", slug=slug, values={})["error"]["data"]["reason"] == "CONNECTOR_NOT_FOUND"
    assert provider["seen"] == []


@pytest.mark.parametrize("url", [None, "http://pal.example.ts.net"])
def test_mcp_redirect_copy_is_omitted_without_an_https_address(root, public_url, url):
    public_url["url"] = url
    steps = {s["id"]: s for s in _row("figma")["setup_guide"]["steps"]}
    assert [c["label"] for c in steps["app"]["copies"]] == ["Scopes"]


def test_figma_and_dropbox_save_through_the_owner_client_path(root, public_url):
    for slug in ("figma", "dropbox"):
        assert _row(slug)["status"] == "needs_setup"
        _ok("connectors.oauth_client.save", slug=slug, client_id_item=_item("fake-id"), client_secret_item=_item(SECRET))
        assert _row(slug)["setup_progress"] == {"step_id": "client", "saved": ["client_id", "client_secret"]}
        assert _row(slug)["status"] == "not_connected"


@pytest.mark.parametrize(("url", "problem", "host"), [
    ("http://pal.example.ts.net", "not_https", "pal.example.ts.net"),
    ("https://100.101.102.103:8443", "ip_host", "100.101.102.103"),
    ("https://[fd7a:115c::1]", "ip_host", "fd7a:115c::1"),
    (PUBLIC_URL, None, None),
    (None, None, None),
])
def test_address_step_reports_the_host_problem(root, public_url, url, problem, host):
    public_url["url"] = url
    steps = {s["id"]: s for s in _row("google-workspace")["setup_guide"]["steps"]}
    assert steps["address"]["problem"] == problem and steps["address"]["problem_host"] == host
    assert all(steps[other]["problem"] is None for other in ("console", "apis", "client"))


def test_progress_returns_to_the_address_while_google_would_reject_it(root, public_url):
    public_url["url"] = "https://100.101.102.103"
    assert _row("google-workspace")["setup_progress"]["step_id"] == "address"
    public_url["url"] = PUBLIC_URL
    assert _row("google-workspace")["setup_progress"]["step_id"] == "console"


def test_google_console_step_carries_the_rejected_address_fallback(root, public_url):
    steps = {s["id"]: s for s in _row("google-workspace")["setup_guide"]["steps"]}
    fallback = steps["console"]["fallback"]
    assert fallback["label"] == "Google rejected the address"
    assert "Desktop app" in fallback["body"] and "own domain" in fallback["body"]
    assert fallback["links"] and all(link["url"].startswith("https://") for link in fallback["links"])
    assert all(s["fallback"] is None for sid, s in steps.items() if sid != "console")
    assert _row("figma")["setup_guide"]["steps"][0]["fallback"] is None


def test_canva_guide_copies_the_gateway_redirect_and_scopes(root, public_url):
    app = _row("canva")["setup_guide"]["steps"][1]
    assert app["copies"][0] == {"label": "Redirect URL", "value": f"{PUBLIC_URL}/webapp/mcp-oauth/callback"}
    assert "profile:read" in app["copies"][1]["value"]
    assert _row("canva")["setup_guide"]["steps"][2]["check"] == "canva_client"
    public_url["url"] = None
    assert [c["label"] for c in _row("canva")["setup_guide"]["steps"][1]["copies"]] == ["Scopes"]


def test_canva_check_sends_the_public_redirect_and_never_leaks_the_secret(root, public_url, provider, caplog):
    caplog.set_level(logging.DEBUG)
    provider["handler"] = lambda _r: httpx.Response(400, json={"error": "invalid_grant"})
    values = {"client_id": _item("OC-fake"), "client_secret": _item(SECRET)}

    result = _ok("connectors.setup.check", slug="canva", values=values)

    assert result == {"slug": "canva", "ok": True, "reason": None, "message": None, "account": None}
    assert "mcp-oauth%2Fcallback" in provider["seen"][0].content.decode()
    provider["handler"] = lambda _r: httpx.Response(401, json={"error": "invalid_client"})
    rejected = _ok("connectors.setup.check", slug="canva", values=values)
    assert rejected["ok"] is False and rejected["reason"] == "INVALID_CLIENT"
    assert SECRET not in json.dumps([result, rejected]) + caplog.text
    assert SECRET not in provider["seen"][0].headers["authorization"]
    public_url["url"] = None
    assert _ok("connectors.setup.check", slug="canva", values=values)["reason"] == "NEEDS_PUBLIC_URL"
