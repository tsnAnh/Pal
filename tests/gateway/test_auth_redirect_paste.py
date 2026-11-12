import asyncio
import json
import logging
import threading
import uuid
from urllib.parse import urlencode

import pytest

from gateway import auth_flows, auth_prompts
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tools import auth_required
from tools.mcp_dashboard_oauth import DashboardOAuthFlow
from tools.oauth_redirect_paste import RedirectPasteError, parse_pasted_redirect
from tui_gateway import mcp_oauth_sessions

pytest_plugins = ('tests.gateway.device_tools_harness',)

REDIRECT = 'http://127.0.0.1:41873/callback'
STATE = 'state-1f9c2'
CODE = 'code-canary-'


@pytest.fixture
def canary():
    return f'{CODE}{uuid.uuid4()}'


@pytest.fixture(autouse=True)
def clean_registry():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()
    mcp_oauth_sessions._sessions.clear()
    auth_flows.unregister('pasteoauth')


def _query(**values):
    return urlencode(values)


def _parse(raw):
    return parse_pasted_redirect(raw, expected_redirect=REDIRECT)


def test_full_final_url_bare_query_and_code_state_all_parse(canary):
    for raw in (f'{REDIRECT}?code={canary}&state={STATE}', f'?code={canary}&state={STATE}',
                f'code={canary}&state={STATE}', f'  {REDIRECT}/?code={canary}&state={STATE}&iss=https%3A%2F%2Fi  \n',
                f'http://localhost:41873/callback?code={canary}&state={STATE}'):
        parsed = _parse(raw)
        assert (parsed.code, parsed.state) == (canary, STATE)
    assert _parse(f'{REDIRECT}?code={canary}&state={STATE}&iss=https%3A%2F%2Fi').iss == 'https://i'


def test_access_denied_is_a_result_not_a_code():
    parsed = _parse(f'{REDIRECT}?error=access_denied&state={STATE}')
    assert (parsed.code, parsed.error, parsed.state) == (None, 'access_denied', STATE)


@pytest.mark.parametrize('raw', [
    '', '   ', None, 42, 'x' * 5000,
    f'{REDIRECT}?code=abc',
    f'{REDIRECT}?code=abc&state=',
    f'{REDIRECT}?state={STATE}',
    f'{REDIRECT}?code=abc&code=def&state={STATE}',
    f'{REDIRECT}?code=abc&state={STATE}&state=other',
    'http://evil.example:41873/callback?code=abc&state=' + STATE,
    'https://127.0.0.1:41873/callback?code=abc&state=' + STATE,
    'http://127.0.0.1:9999/callback?code=abc&state=' + STATE,
    'http://127.0.0.1:41873/other?code=abc&state=' + STATE,
    'http://user:pw@127.0.0.1:41873/callback?code=abc&state=' + STATE,
    'http://127.0.0.1:notaport/callback?code=abc&state=' + STATE,
    'http://127.0.0.1.evil.example:41873/callback?code=abc&state=' + STATE,
])
def test_anything_that_is_not_this_flows_redirect_is_refused(raw):
    with pytest.raises(RedirectPasteError):
        _parse(raw)


def test_refusal_never_carries_the_pasted_text(canary):
    with pytest.raises(RedirectPasteError) as exc:
        _parse(f'http://evil.example/callback?code={canary}&state={STATE}')
    assert canary not in str(exc.value) and canary not in repr(_parse(f'code={canary}&state={STATE}'))


class PastingFlow(auth_flows.McpOAuthFlow):
    created: list = []

    def __init__(self, home, service):
        super().__init__(home, 'mcp:acme')
        self.dashboard = None
        PastingFlow.created.append(self)

    async def authorize_url(self):
        flow = DashboardOAuthFlow(flow_id=uuid.uuid4().hex, server_name='acme', profile=None,
                                  hermes_home=str(self._home), redirect_uri=REDIRECT)
        await flow.publish_authorization_url(f'https://acme.example/authorize?state={STATE}')
        mcp_oauth_sessions.register_flow(flow)
        threading.Thread(target=self._worker, args=(flow,), daemon=True).start()
        self.dashboard = flow
        self._session_id = flow.flow_id
        self._started.set()
        return flow.authorization_url

    @staticmethod
    def _worker(flow):
        flow._callback_ready.wait(10)
        if flow._callback_error:
            flow.mark_error(f'OAuth authorization failed: {flow._callback_error}')
        elif flow._callback:
            flow.mark_approved()


@pytest.fixture(autouse=True)
def pasting_service():
    PastingFlow.created = []
    auth_flows.register('pasteoauth', PastingFlow)


async def _open(authority, phone):
    home = home_of(authority)
    task = asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve(
        'fake_tool', {}, auth_required.http_auth_failure('pasteoauth:acme', 401), lambda: json.dumps({'ok': True}))))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    reply = await phone.call('auth.signin', {'request_id': event['request_id']})
    assert reply['result']['recorded'] is True
    return task, event


@pytest.mark.asyncio
async def test_event_says_paste_is_available_and_older_flows_do_not(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event = await _open(authority, phone)
    assert event['flow'] == 'oauth' and event['redirect_paste'] is True
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task
    for cls in (auth_flows.KeyEntryFlow, auth_flows.HostedConnectorFlow):
        assert getattr(cls, 'accepts_redirect', False) is False


@pytest.mark.asyncio
async def test_another_device_finishes_the_flow_and_every_device_sees_it_end(authorities, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    starter = await connect_phone(authority, label='iPhone')
    finisher = await connect_phone(authority, label='iPad')
    task, event = await _open(authority, starter)
    pasted = f'{REDIRECT}?{_query(code=canary, state=STATE)}'
    reply = await finisher.call('auth.submit_redirect', {'request_id': event['request_id'], 'value': pasted})
    assert reply['result'] == {'outcome': 'accepted'}
    assert json.loads(await task) == {'ok': True}
    for device in (starter, finisher):
        assert device.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert PastingFlow.created[0].dashboard._callback[0] == canary
    events = json.dumps([starter.events('auth.resolved'), finisher.events('auth.resolved'), _required(starter)])
    assert canary not in events + caplog.text


@pytest.mark.asyncio
async def test_pasted_value_is_used_once_and_a_wrong_state_does_not_burn_it(authorities, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event = await _open(authority, phone)
    request = event['request_id']
    wrong = await phone.call('auth.submit_redirect', {'request_id': request, 'value': f'code={canary}&state=forged'})
    garbage = await phone.call('auth.submit_redirect', {'request_id': request, 'value': 'http://evil.example/?code=x&state=y'})
    assert wrong['result'] == garbage['result'] == {'outcome': 'invalid'}
    good = await phone.call('auth.submit_redirect', {'request_id': request, 'value': f'code={canary}&state={STATE}'})
    assert good['result'] == {'outcome': 'accepted'}
    assert json.loads(await task) == {'ok': True}
    replay = await phone.call('auth.submit_redirect', {'request_id': request, 'value': f'code={canary}&state={STATE}'})
    assert replay['result'] == {'outcome': 'rejected'}
    assert canary not in caplog.text


@pytest.mark.asyncio
async def test_access_denied_ends_the_sign_in_with_a_plain_reason(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event = await _open(authority, phone)
    reply = await phone.call('auth.submit_redirect', {
        'request_id': event['request_id'], 'value': f'{REDIRECT}?error=access_denied&state={STATE}'})
    assert reply['result'] == {'outcome': 'accepted'}
    assert json.loads(await task)['error_type'] == 'auth_failed'
    resolved = phone.events('auth.resolved')[-1]
    assert resolved['outcome'] == 'failed' and resolved['reason'] == "Sign-in was declined on the provider's page."


@pytest.mark.asyncio
async def test_another_profile_cannot_finish_the_flow(authorities, canary):
    owner = await authorities('home')
    other = await authorities('other')
    phone = await connect_phone(owner)
    stranger = await connect_phone(other, label='Other iPad')
    task, event = await _open(owner, phone)
    value = f'code={canary}&state={STATE}'
    reply = await stranger.call('auth.submit_redirect', {'request_id': event['request_id'], 'value': value})
    assert reply['result'] == {'outcome': 'rejected'}
    session = PastingFlow.created[0]._session_id
    foreign = mcp_oauth_sessions.deliver_pasted_redirect(session, 'acme', str(home_of(other)), value)
    assert foreign == {'ok': False, 'reason': 'unknown'}
    assert PastingFlow.created[0].dashboard._callback is None
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_unknown_unsigned_in_and_expired_requests_are_rejected(authorities, monkeypatch, canary):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    value = f'code={canary}&state={STATE}'
    assert (await phone.call('auth.submit_redirect', {'request_id': 'a' * 16, 'value': value}))['result'] == {'outcome': 'rejected'}
    monkeypatch.setattr(auth_prompts, 'SIGNIN_TIMEOUT_SECONDS', 0.3)
    home = home_of(authority)
    task = asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve(
        'fake_tool', {}, auth_required.http_auth_failure('pasteoauth:acme', 401), lambda: '{}')))
    await _wait_for(lambda: len(_required(phone)) == 1)
    request = _required(phone)[0]['request_id']
    early = await phone.call('auth.submit_redirect', {'request_id': request, 'value': value})
    assert early['result'] == {'outcome': 'rejected'}
    await phone.call('auth.signin', {'request_id': request})
    await task
    late = await phone.call('auth.submit_redirect', {'request_id': request, 'value': value})
    assert late['result'] == {'outcome': 'rejected'}
    assert phone.events('auth.resolved')[-1]['outcome'] == 'timed_out'


@pytest.mark.asyncio
async def test_read_only_connection_is_refused_and_it_is_not_a_model_tool(authorities, caplog, canary):
    from gateway.session_controls import AuthorityConnection
    from tools.registry import registry
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reader = await connect_phone(authority, label='Watch')
    reader.connection = AuthorityConnection(authority, reader, {'user_id': 'owner', 'capabilities': ['session:read']})
    task, event = await _open(authority, phone)
    reply = await reader.call('auth.submit_redirect', {'request_id': event['request_id'], 'value': f'code={canary}&state={STATE}'})
    assert reply['error']['message'] == 'permission_denied'
    assert PastingFlow.created[0].dashboard._callback is None
    assert not [name for name in registry.get_all_tool_names() if 'redirect' in name or name.startswith('auth')]
    assert canary not in caplog.text
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_reauth_state_is_typed_on_every_device(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority, label='iPhone')
    pad = await connect_phone(authority, label='iPad')
    home = home_of(authority)
    task = asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve(
        'fake_tool', {}, auth_required.http_auth_failure('pasteoauth:acme', 401), lambda: '{}')))
    await _wait_for(lambda: len(_required(phone)) == 1 and len(_required(pad)) == 1)
    for device in (phone, pad):
        event = _required(device)[0]
        assert event['reason'] in ('missing', 'expired', 'revoked')
        assert event['flow'] == 'oauth' and event['redirect_paste'] is True
    await phone.call('auth.decline', {'request_id': _required(phone)[0]['request_id']})
    await task
