import asyncio
import json
import logging
import threading
import uuid

import pytest

from gateway import auth_prompts
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tools import auth_required
from tools.mcp_dashboard_oauth import DashboardOAuthFlow
from tui_gateway import mcp_oauth_sessions

pytest_plugins = ('tests.gateway.device_tools_harness',)

REDIRECT = 'http://127.0.0.1:41873/callback'
STATE = 'state-1f9c2'
AUTHORIZE = f'https://acme.example/authorize?state={STATE}'


@pytest.fixture
def canary():
    return f'code-canary-{uuid.uuid4()}'


@pytest.fixture(autouse=True)
def fake_mcp(monkeypatch):
    started = []
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers',
                        lambda config=None: {'acme': {'url': 'https://acme.example/mcp', 'auth': 'oauth'}})

    def start_flow(home, name, cfg, **kwargs):
        flow = DashboardOAuthFlow(flow_id=uuid.uuid4().hex, server_name=name, profile=None,
                                  hermes_home=home, redirect_uri=REDIRECT)
        asyncio.run(flow.publish_authorization_url(AUTHORIZE))
        mcp_oauth_sessions.register_flow(flow)
        threading.Thread(target=worker, args=(flow,), daemon=True).start()
        started.append(flow)
        return {'session_id': flow.flow_id, 'auth_url': AUTHORIZE, 'flow': 'pkce'}

    def worker(flow):
        flow._callback_ready.wait(10)
        if flow._callback_error:
            flow.mark_error(f'OAuth authorization failed: {flow._callback_error}')
        elif flow._callback:
            flow.mark_approved()

    monkeypatch.setattr(mcp_oauth_sessions, 'start_flow', start_flow)
    yield started
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()
    mcp_oauth_sessions._sessions.clear()


def _reauth(home):
    return asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve(
        'fake_tool', {}, auth_required.http_auth_failure('mcp:acme', 401), lambda: json.dumps({'ok': True}))))


async def _open(authority, *phones):
    task = _reauth(home_of(authority))
    await _wait_for(lambda: all(len(_required(p)) == 1 for p in phones))
    return task, _required(phones[0])[0]


@pytest.mark.asyncio
async def test_every_device_gets_a_typed_paste_request_with_the_authorization_url(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority, label='iPhone')
    pad = await connect_phone(authority, label='iPad')
    task, _ = await _open(authority, phone, pad)
    for device in (phone, pad):
        event = _required(device)[0]
        assert event['flow'] == 'oauth_paste' and event['verification_uri'] == AUTHORIZE
        assert event['reason'] in ('missing', 'expired', 'revoked') and event['server'] == 'acme'
    await phone.call('auth.decline', {'request_id': _required(phone)[0]['request_id']})
    await task


@pytest.mark.asyncio
async def test_a_second_device_finishes_it_and_tokens_path_gets_the_code_once(authorities, fake_mcp, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    starter = await connect_phone(authority, label='iPhone')
    finisher = await connect_phone(authority, label='iPad')
    task, event = await _open(authority, starter, finisher)
    pasted = f'{REDIRECT}?code={canary}&state={STATE}'
    reply = await finisher.call('auth.submit_callback', {'request_id': event['request_id'], 'value': pasted})
    assert reply['result']['outcome'] == 'stored'
    assert json.loads(await task) == {'ok': True}
    assert fake_mcp[0]._callback[0] == canary
    for device in (starter, finisher):
        assert device.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    again = await finisher.call('auth.submit_callback', {'request_id': event['request_id'], 'value': pasted})
    assert again['result']['outcome'] == 'rejected'
    assert canary not in caplog.text + json.dumps(_required(starter) + starter.events('auth.resolved'))


@pytest.mark.asyncio
async def test_wrong_state_or_host_is_retryable_and_never_reaches_the_flow(authorities, fake_mcp, canary):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event = await _open(authority, phone)
    for value in (f'code={canary}&state=forged', f'http://evil.example:41873/callback?code={canary}&state={STATE}',
                  f'{REDIRECT}?code={canary}&code=2&state={STATE}', f'{REDIRECT}?code={canary}'):
        reply = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': value})
        assert reply['result']['outcome'] == 'failed' and reply['result']['reason']
    assert fake_mcp[0]._callback is None
    good = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': f'code=ok&state={STATE}'})
    assert good['result']['outcome'] == 'stored'
    await task


@pytest.mark.asyncio
async def test_access_denied_ends_the_sign_in_with_a_plain_reason(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event = await _open(authority, phone)
    reply = await phone.call('auth.submit_callback', {
        'request_id': event['request_id'], 'value': f'{REDIRECT}?error=access_denied&state={STATE}'})
    assert reply['result']['outcome'] == 'failed'
    assert json.loads(await task)['error_type'] == 'auth_failed'
    assert phone.events('auth.resolved')[-1]['outcome'] == 'failed'


@pytest.mark.asyncio
async def test_another_profile_cannot_finish_it(authorities, fake_mcp, canary):
    owner = await authorities('home')
    other = await authorities('other')
    phone = await connect_phone(owner)
    stranger = await connect_phone(other, label='Other iPad')
    task, event = await _open(owner, phone)
    value = f'code={canary}&state={STATE}'
    reply = await stranger.call('auth.submit_callback', {'request_id': event['request_id'], 'value': value})
    assert reply['result']['outcome'] == 'rejected'
    sid = fake_mcp[0].flow_id
    assert mcp_oauth_sessions.pending_callback(sid, 'acme', str(home_of(other))) is None
    assert fake_mcp[0]._callback is None
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_expired_paste_is_refused_and_a_read_only_connection_cannot_paste(authorities, monkeypatch, canary):
    from gateway import auth_flows
    from gateway.session_controls import AuthorityConnection
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reader = await connect_phone(authority, label='Watch')
    reader.connection = AuthorityConnection(authority, reader, {'user_id': 'owner', 'capabilities': ['session:read']})
    task, event = await _open(authority, phone)
    value = f'code={canary}&state={STATE}'
    denied = await reader.call('auth.submit_callback', {'request_id': event['request_id'], 'value': value})
    assert denied['error']['message'] == 'permission_denied'
    monkeypatch.setattr(auth_flows, 'PASTE_TTL_SECONDS', -1.0)
    flow = auth_prompts._by_id[event['request_id']].flow._inner
    flow._deadline = 0.0
    late = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': value})
    assert late['result']['outcome'] == 'failed'
    await task
    assert phone.events('auth.resolved')[-1]['outcome'] == 'failed'
