"""Hand-over of an OAuth sign-in the owner's app ran on their own computer (``tools/mcp_oauth_import.py``).

Invariants: only an OAuth catalog server accepts it; the stored client is public (no secret, PKCE) and the files
are the ones the MCP OAuth provider reads, so refresh and refresh-token rotation are the provider's own; a
profile's tokens are never visible to another profile; no token reaches a log, config.yaml, the server summary
the app and model read, or the import's own result.
"""

import json
import logging
import time
from pathlib import Path
from urllib.parse import parse_qs

import pytest

from hermes_cli import mcp_catalog
from hermes_cli.mcp_config import _get_mcp_servers, _oauth_tokens_present
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tools import mcp_oauth_import as imp
from tools.mcp_oauth import HermesTokenStorage

ACCESS, REFRESH = "at-canary-5c1e90ab77d2", "rt-canary-1b84e0d6f9a3"
URL = "https://mcp.upwork.com/mcp"
TOKEN_ENDPOINT = "https://auth.upwork.example/oauth2/token"


def _tokens(**override):
    base = dict(client_id="client-abc", redirect_uri="http://127.0.0.1:53682/callback",
                token_endpoint=TOKEN_ENDPOINT, issuer="https://auth.upwork.example",
                access_token=ACCESS, refresh_token=REFRESH, expires_in=3600, scope="read write", token_type="Bearer")
    return imp.OwnerTokens(**{**base, **override})


@pytest.fixture(autouse=True)
def _fresh_manager():
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    yield
    reset_manager_for_tests()


@pytest.fixture
def home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


@pytest.mark.asyncio
async def test_import_writes_a_public_client_and_the_sdk_readable_tokens(home, caplog):
    caplog.set_level(logging.DEBUG)
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    storage = HermesTokenStorage("upwork", hermes_home=home)
    tokens, client, meta = await storage.get_tokens(), await storage.get_client_info(), storage.load_oauth_metadata()
    assert tokens.access_token == ACCESS and tokens.refresh_token == REFRESH and tokens.token_type == "Bearer"
    assert client.client_id == "client-abc" and client.client_secret is None
    assert client.token_endpoint_auth_method == "none"
    assert [str(u) for u in client.redirect_uris] == ["http://127.0.0.1:53682/callback"]
    assert str(meta.token_endpoint) == TOKEN_ENDPOINT and meta.code_challenge_methods_supported == ["S256"]
    assert meta.token_endpoint_auth_methods_supported == ["none"]
    assert json.loads(storage._tokens_path().read_text())["hermes_issuer"] == "https://auth.upwork.example"
    assert _oauth_tokens_present("upwork")
    assert ACCESS not in caplog.text and REFRESH not in caplog.text


@pytest.mark.asyncio
async def test_import_installs_the_catalog_server_with_its_gate_and_no_secret_in_config(home):
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    config = _get_mcp_servers()["upwork"]
    wanted = mcp_catalog._build_server_config(mcp_catalog.get_entry("upwork"), None)
    assert config["url"] == URL and config["auth"] == "oauth" and config["signin_on"] == "owner_app"
    assert config["action_policy"] == wanted["action_policy"] and "client_secret" not in json.dumps(config)
    text = (home / "config.yaml").read_text()
    assert ACCESS not in text and REFRESH not in text


@pytest.mark.asyncio
async def test_an_older_bare_entry_of_the_same_server_gains_the_gate_and_a_foreign_url_is_refused(home):
    from hermes_cli.mcp_config import _save_mcp_server
    assert _save_mcp_server("upwork", {"url": URL, "auth": "oauth", "enabled": True})
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    assert "action_policy" in _get_mcp_servers()["upwork"]
    assert _save_mcp_server("upwork", {"url": "https://elsewhere.example/mcp", "auth": "oauth", "enabled": True})
    assert await imp.import_owner_tokens(home, "upwork", _tokens(access_token="x" * 12)) == imp.SERVER_MISMATCH


@pytest.mark.asyncio
@pytest.mark.parametrize("override", [
    {"token_endpoint": "http://auth.upwork.example/token"},
    {"issuer": "ftp://auth.upwork.example"},
    {"redirect_uri": "http://evil.example/callback"},
    {"client_id": ""},
    {"access_token": ""},
    {"token_type": "mac"},
    {"expires_in": True},
    {"expires_in": 0},
    {"refresh_token": " padded "},
])
async def test_a_malformed_hand_over_writes_nothing(home, override):
    assert await imp.import_owner_tokens(home, "upwork", _tokens(**override)) == imp.INVALID_REQUEST
    assert not _oauth_tokens_present("upwork") and "upwork" not in _get_mcp_servers()


@pytest.mark.asyncio
async def test_only_an_oauth_catalog_server_takes_a_hand_over(home):
    not_oauth = next(e.name for e in mcp_catalog.list_catalog() if e.auth.type != "oauth")
    for name in (not_oauth, "not-in-the-catalog", "../upwork"):
        assert await imp.import_owner_tokens(home, name, _tokens()) == imp.NOT_OAUTH_SERVICE
    assert not (home / "mcp-tokens").exists() or not list((home / "mcp-tokens").glob("*.json"))


@pytest.mark.asyncio
async def test_a_failed_write_restores_the_previous_state(home, monkeypatch):
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    before = HermesTokenStorage("upwork", hermes_home=home).snapshot()

    async def boom(self, tokens):
        raise OSError("disk full")
    monkeypatch.setattr(HermesTokenStorage, "set_tokens", boom)
    assert await imp.import_owner_tokens(home, "upwork", _tokens(access_token="new-access-9999")) == imp.SAVE_FAILED
    assert HermesTokenStorage("upwork", hermes_home=home).snapshot() == before


async def _refresh(access_expired_by=10):
    """Drive the provider's auth flow the way an MCP call does, answering the token endpoint ourselves."""
    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool import sdk_httpx
    httpx = sdk_httpx()
    path = HermesTokenStorage("upwork")._tokens_path()
    data = json.loads(path.read_text())
    data["expires_at"] = time.time() - access_expired_by
    path.write_text(json.dumps(data))
    provider = get_manager().get_or_build_provider("upwork", URL, {})
    flow = provider.async_auth_flow(httpx.Request("POST", URL))
    refresh = await flow.__anext__()
    return provider, flow, refresh, httpx


@pytest.mark.asyncio
async def test_refresh_is_a_public_client_refresh_grant_and_a_rotated_refresh_token_is_persisted(home, caplog):
    caplog.set_level(logging.DEBUG)
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    seen = []
    for presented, issued in ((REFRESH, "rt-rotated-2-77aa31"), ("rt-rotated-2-77aa31", "rt-rotated-3-0c9d5e")):
        _, flow, refresh, httpx = await _refresh()
        form = parse_qs(refresh.content.decode())
        seen.append((str(refresh.url), form, dict(refresh.headers)))
        assert str(refresh.url) == TOKEN_ENDPOINT and refresh.method == "POST"
        assert form["grant_type"] == ["refresh_token"] and form["refresh_token"] == [presented]
        assert form["client_id"] == ["client-abc"] and "client_secret" not in form
        assert "authorization" not in {k.lower() for k in refresh.headers}
        granted = {"access_token": f"at-after-{issued[-6:]}", "token_type": "Bearer", "expires_in": 3600,
                   "refresh_token": issued}
        retried = await flow.asend(httpx.Response(200, json=granted, request=refresh))
        assert retried.headers["authorization"] == f"Bearer at-after-{issued[-6:]}"
        with pytest.raises(StopAsyncIteration):
            await flow.asend(httpx.Response(200, request=retried))
        stored = json.loads(HermesTokenStorage("upwork")._tokens_path().read_text())
        assert stored["refresh_token"] == issued and stored["hermes_issuer"] == "https://auth.upwork.example"
    assert all("code_verifier" not in form for _, form, _ in seen)
    assert REFRESH not in caplog.text and "rt-rotated" not in caplog.text and ACCESS not in caplog.text


@pytest.mark.asyncio
async def test_a_refresh_token_is_never_sent_to_an_issuer_that_did_not_grant_it(home):
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    storage = HermesTokenStorage("upwork", hermes_home=home)
    meta = storage.load_oauth_metadata().model_copy(update={"issuer": "https://other-issuer.example"})
    storage.save_oauth_metadata(meta)
    from tools.mcp_oauth_manager import get_manager
    provider = get_manager().get_or_build_provider("upwork", URL, {})
    await provider._initialize()
    assert provider.context.current_tokens.refresh_token is None
    assert "refresh_token" not in json.loads(storage._tokens_path().read_text())


@pytest.mark.asyncio
async def test_a_profiles_tokens_are_never_used_by_another_profile(tmp_path, home):
    other = tmp_path / "profile-b"
    other.mkdir()
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    assert HermesTokenStorage("upwork", hermes_home=home).has_cached_tokens()
    assert not HermesTokenStorage("upwork", hermes_home=other).has_cached_tokens()
    scope = set_hermes_home_override(other)
    try:
        assert not _oauth_tokens_present("upwork") and "upwork" not in _get_mcp_servers()
        from tools.mcp_oauth import OAuthNonInteractiveError
        from tools.mcp_oauth_manager import get_manager
        with pytest.raises(OAuthNonInteractiveError):
            get_manager().get_or_build_provider("upwork", URL, {})
    finally:
        reset_hermes_home_override(scope)
    assert await imp.import_owner_tokens(other, "upwork", _tokens(access_token="b-access-token-1", refresh_token="b-refresh-1")) is None
    assert (await HermesTokenStorage("upwork", hermes_home=home).get_tokens()).access_token == ACCESS


@pytest.mark.asyncio
async def test_the_server_summary_the_app_and_model_read_carries_no_token(home):
    from tui_gateway.mcp_rpc_helpers import summarize_server
    assert await imp.import_owner_tokens(home, "upwork", _tokens()) is None
    summary = summarize_server("upwork", _get_mcp_servers()["upwork"])
    assert summary["oauth_tokens_present"] is True
    assert ACCESS not in json.dumps(summary) and REFRESH not in json.dumps(summary)
