import asyncio
import logging
import uuid
from urllib.parse import parse_qs, urlsplit

import pytest

import hermes_cli.auth
import providers
from gateway import auth_flows, auth_prompts
from hermes_cli import auth_oauth_pkce_plugin as pkce
from hermes_cli import model_provider_control as control
from hermes_cli.oauth_paste import CallbackError, parse_callback
from providers import register_provider
from providers.base import ProviderProfile
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _wait_for

pytest_plugins = ('tests.gateway.device_tools_harness',)

PROVIDER = 'paste-example'
REDIRECT = 'http://127.0.0.1:51234/callback'
STATE = 'state-value-123'
CFG = pkce.OAuthPKCEConfig(client_id='c', authorize_url='https://idp.example/authorize',
                           token_url='https://idp.example/token', scopes=('inference',), label='Example')


@pytest.fixture(autouse=True)
def clean(request):
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


@pytest.fixture
def provider(request):
    register_provider(ProviderProfile(name=PROVIDER, auth_type='oauth_external', base_url='https://example.invalid/v1',
                                      auth_handler=pkce.pkce_auth_handler(CFG),
                                      refresh_credential=pkce.pkce_refresh_credential(CFG)))
    request.addfinalizer(lambda: (providers._REGISTRY.pop(PROVIDER, None),
                                  hermes_cli.auth.PROVIDER_REGISTRY.pop(PROVIDER, None)))


@pytest.fixture
def canary():
    return f'CANARY-{uuid.uuid4()}'


def _parse(text):
    return parse_callback(text, redirect_uri=REDIRECT, state=STATE)


def _fails(text, code, retry=True):
    with pytest.raises(CallbackError) as caught:
        _parse(text)
    assert caught.value.code == code and caught.value.retry is retry
    return caught.value


@pytest.mark.parametrize('text', [
    f'{REDIRECT}?code=abc&state={STATE}',
    f'  {REDIRECT}?code=abc&state={STATE}\n',
    f'{REDIRECT}?code=abc&state={STATE}#frag',
    f'code=abc&state={STATE}',
    f'?code=abc&state={STATE}',
    f'abc {STATE}',
    f'abc,{STATE}',
    f'abc#{STATE}',
    f'HTTP://127.0.0.1:51234/callback?code=abc&state={STATE}',
])
def test_accepted_shapes_yield_the_code(text):
    assert _parse(text).code == 'abc'


def test_access_denied_is_terminal():
    _fails(f'{REDIRECT}?error=access_denied&state={STATE}', 'denied', retry=False)


def test_missing_and_mismatched_state_are_retryable():
    _fails(f'{REDIRECT}?code=abc', 'missing_state')
    _fails(f'{REDIRECT}?code=abc&state=other', 'state_mismatch')
    _fails('abc other', 'state_mismatch')


def test_missing_code_and_garbage():
    _fails(f'{REDIRECT}?state={STATE}', 'missing_code')
    _fails('hello', 'unrecognized')
    _fails('', 'unrecognized')
    _fails('x' * 5000, 'unrecognized')


def test_duplicate_params_are_refused():
    _fails(f'{REDIRECT}?code=a&code=b&state={STATE}', 'duplicate_param')
    _fails(f'code=a&state={STATE}&state={STATE}', 'duplicate_param')


@pytest.mark.parametrize('url', [
    f'https://evil.example/callback?code=abc&state={STATE}',
    f'http://127.0.0.1:9999/callback?code=abc&state={STATE}',
    f'http://127.0.0.1:51234/other?code=abc&state={STATE}',
    f'https://127.0.0.1:51234/callback?code=abc&state={STATE}',
    f'http://user:pw@127.0.0.1:51234/callback?code=abc&state={STATE}',
    f'http://127.0.0.1:51234@evil.example/callback?code=abc&state={STATE}',
])
def test_wrong_host_port_path_or_scheme_is_refused(url):
    _fails(url, 'wrong_address')


def test_provider_with_pkce_handler_is_oauth_paste(provider):
    pconfig = control.lookup(PROVIDER)
    assert control.kind_of(pconfig) == ('oauth_paste', None)


@pytest.fixture
def exchanged(monkeypatch):
    calls = []

    def post(provider, cfg, data, *, code):
        calls.append(dict(data))
        return {'access_token': 'at-fake', 'refresh_token': 'rt-fake', 'expires_at_ms': 4102444800000,
                'last_refresh': '2026-01-01T00:00:00Z'}

    monkeypatch.setattr(pkce, '_post_token', post)
    return calls


async def _begin(authority, phone):
    reply = await phone.call('auth.begin', {'service': f'provider:{PROVIDER}'})
    assert reply['result']['outcome'] == 'started', reply
    await _wait_for(lambda: phone.events('auth.required'))
    return phone.events('auth.required')[-1]


def _callback_for(event, **override):
    authorize = urlsplit(event['verification_uri'])
    query = parse_qs(authorize.query)
    redirect = query['redirect_uri'][0]
    values = {'code': 'the-code', 'state': query['state'][0], **override}
    return redirect, '&'.join(f'{k}={v}' for k, v in values.items() if v is not None), query


@pytest.mark.asyncio
async def test_full_paste_signs_in_stores_in_the_pool_and_logs_nothing(authorities, provider, exchanged, caplog, canary):
    from agent.credential_pool import load_pool
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    event = await _begin(authority, phone)
    assert event['flow'] == 'oauth_paste' and event['reason'] == 'missing'
    assert event['verification_uri'].startswith('https://idp.example/authorize?')
    redirect, query, params = _callback_for(event, code=canary)
    assert params['code_challenge_method'] == ['S256']
    reply = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': f'{redirect}?{query}'})
    assert reply['result'] == {'outcome': 'stored'}
    await _wait_for(lambda: phone.events('auth.resolved'))
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert exchanged[0]['code'] == canary and exchanged[0]['redirect_uri'] == redirect and exchanged[0]['code_verifier']
    scope = set_hermes_home_override(home_of(authority))
    try:
        entries = load_pool(PROVIDER).entries()
        assert [e.access_token for e in entries] == ['at-fake']
        assert control.row_for(control.lookup(PROVIDER)).state == 'set'
    finally:
        reset_hermes_home_override(scope)
    assert canary not in caplog.text + str(phone.frames)
    again = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': f'{redirect}?{query}'})
    assert again['result']['outcome'] == 'rejected'
    assert len(exchanged) == 1


@pytest.mark.asyncio
async def test_wrong_paste_is_retryable_then_right_paste_works(authorities, provider, exchanged, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    event = await _begin(authority, phone)
    _redirect, query, _ = _callback_for(event)
    bad = await phone.call('auth.submit_callback', {'request_id': event['request_id'],
                                                    'value': f'https://evil.example/x?code={canary}&state=s'})
    assert bad['result']['outcome'] == 'failed' and bad['result']['reason']
    assert not exchanged and canary not in caplog.text + str(bad)
    ok = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert ok['result']['outcome'] == 'stored'


@pytest.mark.asyncio
async def test_denied_ends_the_request_with_a_plain_reason(authorities, provider, exchanged):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    event = await _begin(authority, phone)
    _, query, _ = _callback_for(event, code=None, error='access_denied')
    reply = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert reply['result']['outcome'] == 'failed'
    await _wait_for(lambda: phone.events('auth.resolved'))
    resolved = phone.events('auth.resolved')[-1]
    assert resolved['outcome'] == 'failed' and 'declined' in resolved['reason']
    assert not exchanged


@pytest.mark.asyncio
async def test_failed_exchange_consumes_the_code(authorities, provider, monkeypatch, caplog, canary):
    def boom(*args, **kwargs):
        raise RuntimeError(f'token endpoint said {canary}')

    monkeypatch.setattr(pkce, '_post_token', boom)
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    event = await _begin(authority, phone)
    _, query, _ = _callback_for(event)
    reply = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert reply['result']['outcome'] == 'failed'
    await _wait_for(lambda: phone.events('auth.resolved'))
    assert canary not in caplog.text + str(phone.frames)
    again = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert again['result']['outcome'] == 'rejected'


@pytest.mark.asyncio
async def test_expired_paste_fails_without_exchange(authorities, provider, exchanged, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    event = await _begin(authority, phone)
    _, query, _ = _callback_for(event)
    real = auth_flows.time.monotonic
    monkeypatch.setattr(auth_flows.time, 'monotonic', lambda: real() + auth_flows.PASTE_TTL_SECONDS + 1)
    reply = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert reply['result']['outcome'] == 'failed' and 'expired' in reply['result']['reason']
    assert not exchanged


@pytest.mark.asyncio
async def test_other_flows_and_unknown_requests_reject_a_callback(authorities, provider):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reply = await phone.call('auth.submit_callback', {'request_id': 'f' * 32, 'value': 'code=a&state=b'})
    assert reply['result']['outcome'] == 'rejected'
    bad = await phone.call('auth.submit_callback', {'request_id': 'short', 'value': 'x'})
    assert 'error' in bad


@pytest.mark.asyncio
async def test_callback_needs_the_control_capability(authorities, provider, exchanged):
    from gateway.session_controls import AuthorityConnection
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reader = await connect_phone(authority, label='Watch')
    reader.connection = AuthorityConnection(authority, reader, {'user_id': 'owner', 'capabilities': ['session:read']})
    event = await _begin(authority, phone)
    _, query, _ = _callback_for(event)
    reply = await reader.call('auth.submit_callback', {'request_id': event['request_id'], 'value': query})
    assert reply['error']['message'] == 'permission_denied' and not exchanged


def test_method_is_not_a_model_tool():
    from tools.registry import registry
    assert 'auth.submit_callback' not in registry.get_all_tool_names()


@pytest.mark.asyncio
async def test_expired_pool_credential_is_a_typed_reauth_state(provider):
    from agent.credential_pool import AUTH_TYPE_OAUTH, PooledCredential, load_pool
    load_pool(PROVIDER).add_entry(PooledCredential(
        provider=PROVIDER, id='abc123', label='x', auth_type=AUTH_TYPE_OAUTH, priority=0, source=pkce.POOL_SOURCE,
        access_token='old', refresh_token=None, expires_at_ms=1))
    assert control.row_for(control.lookup(PROVIDER)).state == 'expired'
