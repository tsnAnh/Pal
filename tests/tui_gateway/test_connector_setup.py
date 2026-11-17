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
    row = _row("asana")
    assert row["setup_guide"] is None and row["setup_progress"] is None


def test_slack_guide_carries_the_manifest_with_the_loopback_redirect(root, public_url):
    app = _row("slack")["setup_guide"]["steps"][0]
    manifest = json.loads(app["copies"][0]["value"])
    assert manifest["oauth_config"]["redirect_urls"] == ["http://localhost:27890/callback"]
    assert "chat:write" in manifest["oauth_config"]["scopes"]["user"]


def test_progress_resumes_per_instance(root, public_url, provider):
    provider["handler"] = lambda _r: httpx.Response(400, json={"error": "invalid_grant"})
    assert _row("google-workspace")["setup_progress"] == {"step_id": "console", "saved": []}
    assert _row("slack")["setup_progress"] == {"step_id": "app", "saved": []}
    assert _row("github")["setup_progress"] == {"step_id": "token_page", "saved": []}

    _ok("connectors.oauth_client.save", slug="google-workspace", client_id_item=_item(GOOGLE_ID),
        client_secret_item=_item(SECRET))
    assert _row("google-workspace")["setup_progress"] == {"step_id": "client", "saved": ["client_id", "client_secret"]}
    assert _row("google-workspace", "home")["setup_progress"]["saved"] == ["client_id", "client_secret"]
    assert _row("slack")["setup_progress"]["step_id"] == "app"

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
    provider["handler"] = lambda _r: httpx.Response(200, json={"ok": False, "error": "bad_client_secret"})

    result = _ok("connectors.setup.check", slug="slack",
                 values={"client_id": _item("1.2"), "client_secret": _item(SECRET)})

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
    assert _call("connectors.setup.check", slug="asana", values={})["error"]["data"]["reason"] == "CONNECTOR_NOT_FOUND"
    assert _call("connectors.setup.check", slug="github", values={"token": "missing"})["error"]["data"]["reason"] == "CLIENT_UNREADABLE"
    assert _call("connectors.setup.check", slug="github", values={})["error"]["data"]["reason"] == "INVALID_PARAMS"
    assert provider["seen"] == []


def test_slack_connects_through_the_preregistered_mcp_path_like_asana(root, public_url, monkeypatch):
    started = {}

    def fake_start(home, name, cfg, client_redirect_uri=None):
        started.update(name=name, cfg=cfg)
        return {"session_id": "s1", "auth_url": "https://slack.com/oauth/v2_user/authorize?x=1", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    assert _row("slack")["status"] == "needs_setup"
    saved = _ok("connectors.oauth_client.save", slug="slack", client_id_item=_item("1.2"),
                client_secret_item=_item(SECRET))
    assert saved["redirect_url"] == "http://localhost:27890/callback"
    assert _row("slack")["setup_progress"] == {"step_id": "client", "saved": ["client_id", "client_secret"]}

    assert _ok("connectors.oauth_client.connect", slug="slack")["session_id"] == "s1"
    assert started["name"] == "slack" and started["cfg"]["url"] == "https://mcp.slack.com/mcp"
    assert started["cfg"]["oauth"]["client_id"] == "1.2" and started["cfg"]["oauth"]["redirect_port"] == 27890
    config = (root / "profiles" / "work" / "config.yaml").read_text()
    assert SECRET not in config and "SLACK_CLIENT_SECRET" in config


def test_every_guide_check_has_its_fields_declared():
    for entry in load_pal_connectors():
        for step in (entry.setup.steps if entry.setup else ()):
            if step.check:
                assert tuple(f.id for f in step.fields) == checks.FIELDS[step.check]
