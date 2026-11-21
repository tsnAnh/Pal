from __future__ import annotations

import dataclasses
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_cli import pal_connectors
from hermes_cli.dashboard_auth.middleware import _path_is_public
from hermes_cli.web_routers import oauth_client_metadata
from tests.tools.t3code_double import T3CodeDouble
from tests.waiting import wait_until
from tools.connectors import mcp_oauth as connector_oauth
from tools.connectors.mcp_oauth_redirect import CLIENT_METADATA_PATH, GATEWAY_CALLBACK_PATH
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

pytest.importorskip("mcp.client.auth.oauth2")

PUBLIC = "https://pal.example.ts.net"
OTHER_PUBLIC = "https://work.example.ts.net"
NAME = "posthog"
CIMD_IDS = ("posthog", "resend", "higgsfield")


@pytest.fixture(autouse=True)
def _fresh_state(monkeypatch):
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    monkeypatch.setattr(sessions, "_sessions", {})


@pytest.fixture
def home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def set_public_url(home, url):
    (home / "config.yaml").write_text(f"webapp:\n  public_url: {url}\n" if url else "{}\n")


@pytest.fixture
def client(home):
    app = FastAPI()
    app.include_router(oauth_client_metadata.router)
    return TestClient(app, base_url=PUBLIC)


@pytest.fixture
def vendor(monkeypatch):
    with T3CodeDouble(cimd_only=True) as double:
        entries = tuple(
            dataclasses.replace(e, mcp_url=double.mcp_url) if e.id == NAME else e
            for e in pal_connectors.load_pal_connectors())
        monkeypatch.setattr(pal_connectors, "load_pal_connectors", lambda *_a, **_k: entries)
        yield double


def test_the_shipped_cimd_connectors_are_the_three_that_take_no_registration():
    entries = {e.id: e for e in pal_connectors.load_pal_connectors()}

    assert {cid for cid, e in entries.items() if e.cimd} == set(CIMD_IDS)
    assert all(entries[cid].method is pal_connectors.ConnectionMethod.MCP_OAUTH for cid in CIMD_IDS)


def test_the_document_names_the_gateway_as_the_client_and_its_callback_as_the_only_return(home, client):
    set_public_url(home, PUBLIC)

    response = client.get(CLIENT_METADATA_PATH)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")
    assert response.json() == {
        "client_id": PUBLIC + CLIENT_METADATA_PATH,
        "client_name": "Pal",
        "redirect_uris": [PUBLIC + GATEWAY_CALLBACK_PATH],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none"}
    assert "nousresearch" not in response.text


@pytest.mark.parametrize("configured", [None, "http://pal.example.ts.net", OTHER_PUBLIC])
def test_the_document_is_not_served_for_a_host_that_is_not_an_https_public_address(home, client, configured):
    set_public_url(home, configured)

    assert client.get(CLIENT_METADATA_PATH).status_code == 404


def test_the_document_is_the_owning_profiles_for_the_host_it_was_asked_on(home, client, tmp_path, monkeypatch):
    work = tmp_path / "work-home"
    work.mkdir()
    set_public_url(home, PUBLIC)
    set_public_url(work, OTHER_PUBLIC)
    monkeypatch.setattr(
        "hermes_cli.profiles.list_profiles",
        lambda **_k: [type("P", (), {"path": work})()])

    mine = client.get(CLIENT_METADATA_PATH).json()
    theirs = TestClient(client.app, base_url=OTHER_PUBLIC).get(CLIENT_METADATA_PATH).json()

    assert mine["redirect_uris"] == [PUBLIC + GATEWAY_CALLBACK_PATH]
    assert theirs["client_id"] == OTHER_PUBLIC + CLIENT_METADATA_PATH
    assert theirs["redirect_uris"] == [OTHER_PUBLIC + GATEWAY_CALLBACK_PATH]


def test_a_vendor_can_fetch_the_document_without_signing_in():
    assert _path_is_public(CLIENT_METADATA_PATH)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def approve(attempt_url: str) -> tuple[str, str]:
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        opener.open(attempt_url, timeout=10)
    except urllib.error.HTTPError as redirect:
        query = parse_qs(urlsplit(redirect.headers["Location"]).query)
        return query["code"][0], query["state"][0]
    raise AssertionError("the vendor did not redirect")


def rpc(method, **params):
    response = server._methods[method](1, {k: v for k, v in params.items()})
    return response


def add_server(vendor):
    added = rpc("mcp.servers.add", name=NAME, config={"url": vendor.mcp_url, "transport": "http"})
    assert "error" not in added, added


def test_the_rpc_sign_in_uses_the_gateway_document_and_returns_to_the_gateway_callback(home, vendor):
    set_public_url(home, PUBLIC)
    add_server(vendor)

    started = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri="dev.tsnanh.hermes.bot:/mcp-oauth/callback",
                  fallback_redirect_uri="http://127.0.0.1:53682/callback")["result"]

    assert started["redirect"] == "gateway"
    code, state = approve(started["auth_url"])
    assert sessions.deliver_gateway_callback(state, code=code)
    wait_until(lambda: rpc("mcp.servers.oauth.poll", name=NAME, session_id=started["session_id"])["result"]["status"]
               == "approved", what="sign-in approved")

    assert vendor.registrations == []
    assert [a["client_id"] for a in vendor.authorizations] == [PUBLIC + CLIENT_METADATA_PATH]
    assert [a["redirect_uri"] for a in vendor.authorizations] == [PUBLIC + GATEWAY_CALLBACK_PATH]
    assert vendor.token_requests[0]["client_id"] == PUBLIC + CLIENT_METADATA_PATH
    everything = repr((vendor.requests, vendor.authorizations, vendor.token_requests))
    assert "nousresearch" not in everything


def test_the_card_sign_in_returns_to_the_gateway_callback_too(home, vendor):
    set_public_url(home, PUBLIC)
    add_server(vendor)

    attempt = connector_oauth.start(NAME)

    code, state = approve(attempt.auth_url)
    assert sessions.deliver_gateway_callback(state, code=code)
    wait_until(lambda: attempt.flow.snapshot().get("status") == "approved", what="sign-in approved")
    assert vendor.registrations == []
    assert [a["client_id"] for a in vendor.authorizations] == [PUBLIC + CLIENT_METADATA_PATH]
    assert [a["redirect_uri"] for a in vendor.authorizations] == [PUBLIC + GATEWAY_CALLBACK_PATH]


@pytest.mark.parametrize("configured", [None, "http://pal.example.ts.net"])
def test_without_an_https_public_address_the_sign_in_is_unavailable_and_the_vendor_is_never_contacted(
        home, vendor, configured):
    set_public_url(home, configured)
    add_server(vendor)
    before = list(vendor.requests)

    refused = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri="dev.tsnanh.hermes.bot:/mcp-oauth/callback")

    assert refused["error"]["code"] == 4412
    assert "public web address" in refused["error"]["message"]
    assert vendor.requests == before and vendor.registrations == [] and vendor.authorizations == []
    with pytest.raises(Exception, match="public web address"):
        connector_oauth.start(NAME)
    assert vendor.requests == before


def test_a_custom_server_that_borrows_the_name_never_presents_the_gateway_document(home, monkeypatch):
    set_public_url(home, PUBLIC)
    with T3CodeDouble(cimd_only=True) as double:
        added = rpc("mcp.servers.add", name=NAME, config={"url": double.mcp_url, "transport": "http"})
        assert "error" not in added, added

        started = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri="http://127.0.0.1:53682/callback")

        assert "error" in started
        assert double.authorizations == []


def test_the_nous_client_document_stays_unreachable_for_pal_workers():
    from tools.mcp_oauth import _maybe_use_cimd
    assert _maybe_use_cimd(connector_oauth._without_cimd({"url": "https://x.example/mcp"})["oauth"]) is None
