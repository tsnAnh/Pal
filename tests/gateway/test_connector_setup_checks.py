import base64
import logging
from urllib.parse import parse_qs

import httpx
import pytest

from gateway import connector_setup_checks as checks

SECRET = "fake-secret-do-not-use"


def _transport(handler, seen=None):
    def wrapped(request):
        if seen is not None:
            seen.append(request)
        return handler(request)
    return httpx.MockTransport(wrapped)


def _json(status, body):
    return lambda _request: httpx.Response(status, json=body)


GOOGLE = {"client_id": "fake.apps.googleusercontent.com", "client_secret": SECRET}
CANVA = {"client_id": "OC-fake", "client_secret": SECRET}


@pytest.mark.parametrize("error,ok,reason", [
    ("invalid_grant", True, None),
    ("invalid_client", False, "invalid_client"),
    ("unauthorized_client", False, "invalid_client"),
    ("redirect_uri_mismatch", False, "check_unavailable"),
])
def test_google_client_reads_the_provider_error(error, ok, reason):
    seen = []
    outcome = checks.run_check("google_client", GOOGLE, redirect_url="https://pal.example/cb",
                               transport=_transport(_json(400, {"error": error}), seen))
    assert (outcome.ok, outcome.reason) == (ok, reason)
    body = seen[0].content.decode()
    assert "grant_type=authorization_code" in body and "redirect_uri=https%3A%2F%2Fpal.example%2Fcb" in body


def test_google_client_needs_a_redirect_without_calling_google():
    seen = []
    outcome = checks.run_check("google_client", GOOGLE, transport=_transport(_json(400, {}), seen))
    assert outcome.reason == "needs_public_url" and seen == []


def test_github_token_accepts_and_names_the_account():
    seen = []
    outcome = checks.run_check("github_token", {"token": SECRET},
                               transport=_transport(_json(200, {"login": "octo"}), seen))
    assert outcome.ok and outcome.account == "octo"
    assert seen[0].headers["authorization"] == f"Bearer {SECRET}"


@pytest.mark.parametrize("status,reason", [(401, "invalid_token"), (403, "invalid_token"), (502, "check_unavailable")])
def test_github_token_rejections(status, reason):
    outcome = checks.run_check("github_token", {"token": SECRET}, transport=_transport(_json(status, {})))
    assert (outcome.ok, outcome.reason) == (False, reason)


@pytest.mark.parametrize("status,error,ok,reason", [
    (400, "invalid_grant", True, None),
    (401, "invalid_client", False, "invalid_client"),
    (401, "invalid_access_token", False, "invalid_client"),
    (400, "invalid_request", False, "check_unavailable"),
    (500, "server_error", False, "check_unavailable"),
])
def test_canva_client_reads_the_token_endpoint_answer(status, error, ok, reason):
    seen = []
    outcome = checks.run_check("canva_client", CANVA, redirect_url="https://pal.example/cb",
                               transport=_transport(_json(status, {"error": error}), seen))
    assert (outcome.ok, outcome.reason) == (ok, reason)
    request = seen[0]
    expected = base64.b64encode(f"OC-fake:{SECRET}".encode()).decode()
    assert request.headers["authorization"] == f"Basic {expected}"
    form = parse_qs(request.content.decode())
    assert form["grant_type"] == ["authorization_code"] and form["redirect_uri"] == ["https://pal.example/cb"]
    assert len(form["code_verifier"][0]) == 64 and form["code"][0]
    assert SECRET not in request.content.decode()


def test_canva_client_needs_a_redirect_without_calling_canva():
    seen = []
    outcome = checks.run_check("canva_client", CANVA, transport=_transport(_json(400, {}), seen))
    assert outcome.reason == "needs_public_url" and seen == []


@pytest.mark.parametrize("kind,values", [("google_client", GOOGLE), ("canva_client", CANVA),
                                         ("github_token", {"token": SECRET})])
def test_network_failure_is_unavailable_and_logs_no_secret(kind, values, caplog):
    caplog.set_level(logging.DEBUG)

    def boom(request):
        raise httpx.ConnectError(f"cannot reach {SECRET}", request=request)

    outcome = checks.run_check(kind, values, redirect_url="https://pal.example/cb", transport=httpx.MockTransport(boom))

    assert outcome.reason == "check_unavailable"
    assert SECRET not in caplog.text and SECRET not in repr(outcome)
    assert "ConnectError" in caplog.text


def test_non_json_body_is_unavailable():
    outcome = checks.run_check("canva_client", CANVA, redirect_url="https://pal.example.ts.net/webapp/mcp-oauth/callback",
                               transport=_transport(lambda _r: httpx.Response(200, text="<html>")))
    assert outcome.reason == "check_unavailable"
