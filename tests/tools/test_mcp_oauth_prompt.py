from __future__ import annotations

import asyncio

import pytest

from tests.tools.mcp_accounts_double import AccountsDouble, follow_authorization
from tools.mcp_oauth import HermesTokenStorage, _authorization_code_result

pytest.importorskip("mcp.client.auth.oauth2")

SELECT_ACCOUNT = "select_account login"


@pytest.fixture
def double():
    with AccountsDouble() as d:
        yield d


async def sign_in(double: AccountsDouble, name: str, oauth_config: dict | None) -> str:
    from tools.mcp_oauth_manager import _HERMES_PROVIDER_CLS, reset_manager_for_tests
    from tools.mcp_oauth_provider import build_provider_kwargs, prepare_oauth_config
    from tools.mcp_tool import sdk_httpx

    reset_manager_for_tests()
    cfg, storage = prepare_oauth_config(name, double.mcp_url, oauth_config)
    kwargs = build_provider_kwargs(cfg, storage, ssh_proxy_hint=False)
    landed = {}

    async def redirect(authorization_url: str) -> None:
        landed.update(await asyncio.to_thread(follow_authorization, authorization_url))

    async def callback():
        return _authorization_code_result(landed["code"], landed["state"])

    kwargs.update(redirect_handler=redirect, callback_handler=callback)
    provider = _HERMES_PROVIDER_CLS(server_name=name, server_url=double.mcp_url, **kwargs)
    async with sdk_httpx().AsyncClient(auth=provider) as client:
        await client.post(double.mcp_url, json={"jsonrpc": "2.0", "id": 1, "method": "ping"})
    return (await HermesTokenStorage(name).get_tokens()).access_token


@pytest.mark.asyncio
async def test_a_configured_prompt_is_sent_to_the_authorization_server(double):
    double.sign_in_as("work")

    token = await sign_in(double, "linear@work", {"prompt": SELECT_ACCOUNT})

    assert double.authorize_queries[-1]["prompt"] == SELECT_ACCOUNT
    assert double.account_by_token[token] == "work"


@pytest.mark.asyncio
async def test_no_prompt_is_sent_unless_one_is_configured(double):
    double.sign_in_as("work")

    await sign_in(double, "linear@work", None)

    assert "prompt" not in double.authorize_queries[-1]


@pytest.mark.asyncio
async def test_a_prompt_already_on_the_authorization_url_is_never_overridden():
    from tools.mcp_oauth_manager import _HERMES_PROVIDER_CLS
    from mcp.shared.auth import OAuthClientMetadata
    from pydantic import AnyUrl

    seen = []

    async def redirect(url):
        seen.append(url)

    metadata = OAuthClientMetadata(redirect_uris=[AnyUrl("http://127.0.0.1:1/cb")], client_name="Hermes Agent")
    provider = _HERMES_PROVIDER_CLS(
        server_name="linear@work", server_url="https://mcp.example/mcp", storage=HermesTokenStorage("linear@work"),
        client_metadata=metadata, redirect_handler=redirect, callback_handler=None,
        authorization_prompt=SELECT_ACCOUNT)
    provider._request_authorization_prompt()
    wrapped = provider.context.redirect_handler
    provider._request_authorization_prompt()
    assert provider.context.redirect_handler is wrapped

    await wrapped("https://as.example/authorize?prompt=none&x=1")
    await wrapped("https://as.example/authorize?x=2")

    assert "prompt=none" in seen[0] and SELECT_ACCOUNT.replace(" ", "+") not in seen[0]
    assert "prompt=select_account+login" in seen[1]
