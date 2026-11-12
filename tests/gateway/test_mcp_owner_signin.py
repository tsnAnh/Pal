"""Sign-in on the owner's own computer for an MCP server whose vendor refuses a redirect from this host.

Invariants: the sign-in prompt says so with a typed hint and the gateway never starts its own browser flow for
that server; ``auth.submit_oauth_tokens`` stores the hand-over for the connecting profile only, ends the waiting
request as signed in and lets the call retry; it accepts a public client only; no token reaches a frame, a log,
the config or the model.
"""

import asyncio
import json
import logging

import pytest

from gateway import auth_prompts
from hermes_cli import mcp_catalog
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tools import auth_required
from tools.registry import tool_error

pytest_plugins = ('tests.gateway.device_tools_harness',)

ACCESS, REFRESH = 'at-canary-5c1e90ab77d2', 'rt-canary-1b84e0d6f9a3'
HANDOVER = {
    'service': 'mcp:upwork', 'client_id': 'client-abc', 'redirect_uri': 'http://127.0.0.1:53682/callback',
    'token_endpoint': 'https://auth.upwork.example/oauth2/token', 'issuer': 'https://auth.upwork.example',
    'access_token': ACCESS, 'refresh_token': REFRESH, 'expires_in': 3600, 'scope': 'read', 'token_type': 'Bearer'}


@pytest.fixture(autouse=True)
def clean_registry():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


def _upwork_config():
    return mcp_catalog._build_server_config(mcp_catalog.get_entry('upwork'), None)


def _reauth():
    return tool_error('MCP server needs re-authentication.', needs_reauth=True, server='upwork')


def _tokens_on_disk(authority):
    folder = home_of(authority) / 'mcp-tokens'
    return sorted(p.name for p in folder.glob('*.json')) if folder.exists() else []


@pytest.mark.asyncio
async def test_the_prompt_says_sign_in_on_your_computer_and_the_gateway_starts_no_browser_flow(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers', lambda config=None: {'upwork': _upwork_config()})

    def refuse_to_start(*args, **kwargs):
        raise AssertionError('the gateway host must not start this sign-in')
    monkeypatch.setattr('tui_gateway.mcp_oauth_sessions.start_flow', refuse_to_start)
    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'mcp_upwork_x', {}, _reauth(), lambda: json.dumps({'ok': True}))))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['flow'] == 'oauth' and event['signin_on'] == 'owner_app' and event['server'] == 'upwork'
    reply = await phone.call('auth.signin', {'request_id': event['request_id']})
    assert reply['result'] == {'recorded': True}
    assert not task.done()
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_an_ordinary_oauth_server_keeps_its_gateway_flow_and_carries_no_hint(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers',
                        lambda config=None: {'acme': {'url': 'https://acme.example/mcp', 'auth': 'oauth'}})

    async def begin(self):
        self.verification_uri = 'https://acme.example/authorize'

    monkeypatch.setattr('gateway.auth_flows.McpPasteFlow.begin', begin)
    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'mcp_acme_x', {}, tool_error('x', needs_reauth=True, server='acme'), lambda: '{}')))
    await _wait_for(lambda: len(_required(phone)) == 1)
    assert 'signin_on' not in _required(phone)[0]
    await phone.call('auth.decline', {'request_id': _required(phone)[0]['request_id']})
    await task


def test_neither_gateway_oauth_entry_point_starts_a_flow_for_that_server():
    from tools.connectors import mcp_oauth
    from tui_gateway import mcp_oauth_sessions
    with pytest.raises(RuntimeError, match='your own computer'):
        mcp_oauth_sessions.start_flow('/tmp/none', 'upwork', {**_upwork_config(), 'auth': 'oauth'})
    from hermes_cli.mcp_config import _save_mcp_server
    assert _save_mcp_server('upwork', _upwork_config())
    with pytest.raises(RuntimeError, match='your own computer'):
        mcp_oauth.start('upwork')


@pytest.mark.asyncio
async def test_the_hand_over_signs_the_waiting_request_in_and_the_call_retries(authorities, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers', lambda config=None: {'upwork': _upwork_config()})
    retries = []

    def retry():
        retries.append(1)
        return json.dumps({'ok': True})

    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'mcp_upwork_x', {}, _reauth(), retry)))
    await _wait_for(lambda: len(_required(phone)) == 1)
    reply = await phone.call('auth.submit_oauth_tokens', HANDOVER)
    assert reply['result'] == {'ok': True}
    assert json.loads(await task) == {'ok': True} and retries == [1]
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert _tokens_on_disk(authority) == ['upwork.client.json', 'upwork.json', 'upwork.meta.json']
    everything = json.dumps(phone.frames) + json.dumps(reply) + caplog.text
    assert ACCESS not in everything and REFRESH not in everything


@pytest.mark.asyncio
async def test_a_client_secret_is_not_a_field_the_wire_accepts(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'client_secret': 'shh-secret-value'})
    assert reply['error']['code'] == 4001 and 'result' not in reply
    assert _tokens_on_disk(authority) == []
    assert 'shh-secret-value' not in json.dumps(reply)


@pytest.mark.asyncio
@pytest.mark.parametrize('override,reason', [
    ({'service': 'mcp:not-in-the-catalog'}, 'not_oauth_service'),
    ({'token_endpoint': 'http://auth.upwork.example/token'}, 'invalid_request'),
])
async def test_a_refused_hand_over_answers_a_reason_and_stores_nothing(authorities, override, reason, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, **override})
    assert reply['result'] == {'ok': False, 'reason': reason}
    assert _tokens_on_disk(authority) == [] and ACCESS not in caplog.text + json.dumps(reply)


@pytest.mark.asyncio
async def test_each_profile_stores_its_own_hand_over(authorities):
    first, second = await authorities('home'), await authorities('other')
    one, two = await connect_phone(first), await connect_phone(second)
    assert (await one.call('auth.submit_oauth_tokens', HANDOVER))['result'] == {'ok': True}
    assert _tokens_on_disk(first) and _tokens_on_disk(second) == []
    assert (await two.call('auth.submit_oauth_tokens', {**HANDOVER, 'access_token': 'b-access-1', 'refresh_token': 'b-refresh-1'}))['result'] == {'ok': True}
    stored = json.loads((home_of(first) / 'mcp-tokens' / 'upwork.json').read_text())
    assert stored['access_token'] == ACCESS
    assert json.loads((home_of(second) / 'mcp-tokens' / 'upwork.json').read_text())['access_token'] == 'b-access-1'


def test_an_action_gated_server_reaches_session_kinds_exactly_like_any_other_connector():
    from gateway.session_policy import _resolve_toolsets
    from tools.mcp_tool_schema import mcp_prefixed_tool_name
    from tools.registry import registry
    from toolsets import resolve_toolset
    names = {server: mcp_prefixed_tool_name(server, 'search') for server in ('upwork', 'linear')}
    try:
        for server, tool in names.items():
            registry.register(name=tool, toolset=f'mcp-{server}', schema={'name': tool, 'description': 'x', 'parameters': {
                'type': 'object', 'properties': {}}}, handler=lambda args, **kw: '{}')
            registry.register_toolset_alias(server, f'mcp-{server}')
        assert resolve_toolset('upwork') == [names['upwork']] and resolve_toolset('linear') == [names['linear']]
        for source in ('ios', 'gui', 'tui', 'cli'):
            resolved = set(_resolve_toolsets({}, {}, source, False))
            assert ('upwork' in resolved or 'mcp-upwork' in resolved) == ('linear' in resolved or 'mcp-linear' in resolved)
    finally:
        for tool in names.values():
            registry.deregister(tool)
