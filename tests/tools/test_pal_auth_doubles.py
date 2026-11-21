from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request
from urllib.parse import urlencode

import pytest

from tests.tools.oauth_server_double import ALL_REDIRECT_KINDS, APP, GATEWAY, LOOPBACK, OAuthServerDouble, redirect_kind
from tests.tools.pal_auth_harness import LOOPBACK_REDIRECT, PUBLIC_URL, Browser, NetworkGuard
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI

pytest_plugins = ("tests.tools.pal_auth_harness",)

CIMD_REDIRECT = "http://127.0.0.1:27890/callback"


def register(authorization: OAuthServerDouble, redirect_uri: str) -> int:
    request = urllib.request.Request(
        f"{authorization.base}/register", data=json.dumps({"redirect_uris": [redirect_uri]}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(request, timeout=10).status
    except urllib.error.HTTPError as refused:
        return refused.code


def authorize(authorization: OAuthServerDouble, client_id: str, redirect_uri: str) -> int | dict:
    query = urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri, "state": "s",
                       "code_challenge": "c" * 43, "code_challenge_method": "S256"})
    try:
        return Browser().authorize(f"{authorization.base}/authorize?{query}")
    except AssertionError as failure:
        return int(str(failure).split("answered ")[1].split(":")[0])


def test_the_guard_refuses_and_names_a_nous_host_and_any_other_host_off_this_machine(monkeypatch):
    guard = NetworkGuard(monkeypatch)

    with pytest.raises(ConnectionRefusedError):
        socket.create_connection(("portal.nousresearch.com", 443), timeout=1)
    with pytest.raises(ConnectionRefusedError):
        socket.getaddrinfo("nousresearch.github.io", 443)
    with pytest.raises(ConnectionRefusedError):
        socket.socket().connect(("203.0.113.9", 80))
    with pytest.raises(AssertionError, match="Nous host"):
        guard.assert_stayed_home()

    assert guard.hosts == ["portal.nousresearch.com", "nousresearch.github.io", "203.0.113.9"]


def test_the_guard_records_loopback_traffic_without_refusing_it(guard):
    with OAuthServerDouble() as authorization:
        urllib.request.urlopen(f"{authorization.base}/.well-known/oauth-authorization-server", timeout=10).read()

    assert guard.hosts == ["127.0.0.1"] and guard.refused == []


def test_an_authorization_server_that_takes_loopback_only_refuses_the_app_and_https_redirects(guard):
    with OAuthServerDouble(accepted_redirects=frozenset({LOOPBACK})) as authorization:
        outcomes = {uri: register(authorization, uri) for uri in (APP_REDIRECT_URI, PUBLIC_URL + "/cb", LOOPBACK_REDIRECT)}

    assert outcomes == {APP_REDIRECT_URI: 400, PUBLIC_URL + "/cb": 400, LOOPBACK_REDIRECT: 201}
    assert {redirect_kind(u) for u in outcomes} == ALL_REDIRECT_KINDS == {APP, GATEWAY, LOOPBACK}


def test_an_authorization_server_without_registration_advertises_none_and_answers_404(guard):
    with OAuthServerDouble(dcr=False) as authorization:
        metadata = json.loads(urllib.request.urlopen(
            f"{authorization.base}/.well-known/oauth-authorization-server", timeout=10).read())

        assert "registration_endpoint" not in metadata
        assert register(authorization, LOOPBACK_REDIRECT) == 404


def test_a_client_id_document_is_fetched_and_its_redirect_uris_decide_what_the_server_accepts(guard):
    with OAuthServerDouble(cimd=True) as authorization:
        client_id = authorization.publish_client_document("pal", [CIMD_REDIRECT])
        metadata = json.loads(urllib.request.urlopen(
            f"{authorization.base}/.well-known/oauth-authorization-server", timeout=10).read())

        listed = authorize(authorization, client_id, CIMD_REDIRECT)
        unlisted = authorize(authorization, client_id, "http://127.0.0.1:1/other")
        unknown = authorize(authorization, f"{authorization.base}/clients/missing", CIMD_REDIRECT)

    assert metadata["client_id_metadata_document_supported"] is True
    assert isinstance(listed, dict) and listed["state"] == "s"
    assert (unlisted, unknown) == (400, 400)
    assert authorization.log.cimd_fetches[0] == client_id


def test_a_server_that_does_not_advertise_client_id_documents_never_fetches_one(guard):
    with OAuthServerDouble() as authorization:
        client_id = authorization.publish_client_document("pal", [CIMD_REDIRECT])

        refused = authorize(authorization, client_id, CIMD_REDIRECT)

    assert refused == 400 and authorization.log.cimd_fetches == []
