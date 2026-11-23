"""Trello's hosted MCP server signs in through the stock native OAuth path, with no client registered up front.

The server answers its protected-resource metadata only at the RFC 9728 path-suffixed address and names an
Atlassian authorization server that offers Dynamic Client Registration with public clients and PKCE S256.
A mock transport stands in for both hosts; no network.
"""
from __future__ import annotations

import json
from urllib.parse import parse_qsl, urlsplit

import pytest

pytest.importorskip("mcp.client.auth.oauth2")

RESOURCE = "https://mcp.trello.com/v1"
PRM_PATHED = "https://mcp.trello.com/.well-known/oauth-protected-resource/v1"
ISSUER = "https://auth.atlassian.com/VCeDsk8ZHncYF1g234fKtc4lNipbBhu3"
REGISTRATION = f"{ISSUER}/dcr/register"
SCOPES = [
    "offline_access", "read:me", "read:account", "read:board:trello", "write:board:trello",
    "read:organization:trello", "write:organization:trello", "read:member:trello",
    "read:member.inbox:trello", "write:member.inbox:trello", "read:member.planner:trello",
    "write:member.planner:trello",
]


def _trello(httpx, seen, *, hint):
    def handler(request):
        url = str(request.url)
        seen["requests"].append((request.method, url))
        reply = lambda status, body=None: httpx.Response(status, json=body or {}, request=request)
        if url == RESOURCE:
            if request.headers.get("Authorization") == "Bearer AT-1":
                return reply(200, {"ok": True})
            challenge = {"WWW-Authenticate": f'Bearer resource_metadata="{PRM_PATHED}"'} if hint else {}
            return httpx.Response(401, json={}, headers=challenge, request=request)
        if url == PRM_PATHED:
            return reply(200, {"resource": RESOURCE, "authorization_servers": [ISSUER],
                               "bearer_methods_supported": ["header"], "scopes_supported": SCOPES})
        if url == "https://auth.atlassian.com/.well-known/oauth-authorization-server/VCeDsk8ZHncYF1g234fKtc4lNipbBhu3":
            return reply(200, {
                "issuer": ISSUER, "authorization_endpoint": "https://auth.atlassian.com/authorize",
                "token_endpoint": "https://auth.atlassian.com/oauth/token", "registration_endpoint": REGISTRATION,
                "response_types_supported": ["code"], "code_challenge_methods_supported": ["S256"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"]})
        if url == REGISTRATION:
            seen["registration"] = json.loads(request.content)
            return reply(201, {**seen["registration"], "client_id": "dcr-1"})
        if url == "https://auth.atlassian.com/oauth/token":
            seen["token_form"] = dict(parse_qsl(request.content.decode()))
            return reply(200, {"access_token": "AT-1", "token_type": "Bearer", "expires_in": 3600, "refresh_token": "RT-1"})
        return httpx.Response(503, text="no_healthy_upstream", request=request)

    return handler


@pytest.mark.asyncio
@pytest.mark.parametrize("hint", [True, False], ids=["www-authenticate-hint", "well-known-fallback"])
async def test_trello_signs_in_through_path_suffixed_discovery_and_dynamic_registration(tmp_path, monkeypatch, hint):
    from tools.mcp_oauth import HermesTokenStorage, _authorization_code_result, _build_client_metadata
    from tools.mcp_oauth_manager import _HERMES_PROVIDER_CLS, reset_manager_for_tests
    from tools.mcp_tool import sdk_httpx

    httpx = sdk_httpx()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    reset_manager_for_tests()
    seen = {"requests": []}

    async def redirect(url):
        seen["authorize_url"] = url

    async def callback():
        return _authorization_code_result("code-1", dict(parse_qsl(urlsplit(seen["authorize_url"]).query))["state"])

    provider = _HERMES_PROVIDER_CLS(
        server_name="trello", server_url=RESOURCE, storage=HermesTokenStorage("trello"),
        client_metadata=_build_client_metadata({"_resolved_port": 1}),
        redirect_handler=redirect, callback_handler=callback)
    async with httpx.AsyncClient(auth=provider, transport=httpx.MockTransport(_trello(httpx, seen, hint=hint))) as client:
        response = await client.get(RESOURCE)

    assert response.status_code == 200
    urls = [url for _method, url in seen["requests"]]
    prm_attempts = [url for url in urls if "/.well-known/oauth-protected-resource" in url]
    assert prm_attempts == [PRM_PATHED]
    assert ("POST", REGISTRATION) in seen["requests"]
    assert seen["registration"]["token_endpoint_auth_method"] == "none"
    assert "client_secret" not in seen["registration"]
    query = dict(parse_qsl(urlsplit(seen["authorize_url"]).query))
    assert urlsplit(seen["authorize_url"])._replace(query="").geturl() == "https://auth.atlassian.com/authorize"
    assert query["client_id"] == "dcr-1" and query["code_challenge_method"] == "S256"
    assert set(query["scope"].split()) == set(SCOPES)
    assert "client_secret" not in seen["token_form"] and seen["token_form"]["code_verifier"]
