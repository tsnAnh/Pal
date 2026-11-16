import asyncio
import json
import logging

import pytest

from gateway import auth_flows, auth_prompts
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tests.gateway.device_tools_harness import connect_phone, home_of
from tools import auth_required
from tui_gateway import google_workspace as gw
from tui_gateway import server

pytest_plugins = ('tests.gateway.device_tools_harness',)

CANARY = 'ya29.CANARYTOKEN0123456789'
SERVICE = auth_required.GOOGLE_WORKSPACE_SERVICE
FAILING = json.dumps({'output': f'TOKEN_REVOKED: invalid_grant {CANARY}', 'exit_code': 1})
COMMAND = {'command': 'python /h/skills/productivity/google-workspace/scripts/setup.py --check'}


@pytest.fixture(autouse=True)
def clean_prompts():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


def _in_home(home, fn):
    def run():
        token = set_hermes_home_override(home)
        try:
            return fn()
        finally:
            reset_hermes_home_override(token)
    return asyncio.to_thread(run)


async def _wait_for(predicate, timeout=5.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        assert asyncio.get_running_loop().time() < deadline, 'condition not reached'
        await asyncio.sleep(0.02)


def _finish_rpc():
    return server.handle_request({'jsonrpc': '2.0', 'id': 1, 'method': 'google_workspace.signin.finish',
                                  'params': {'flow_id': 'f', 'pasted': 'p'}})


@pytest.mark.asyncio
async def test_flow_registered_for_google_and_cancel_is_not_a_sign_in():
    flow = auth_flows.flow_for(None, SERVICE)
    assert (flow.kind, flow.signin_on, flow.user_code, flow.verification_uri) == ('oauth_paste', 'owner_app', None, None)
    assert flow.expires_in == int(auth_flows.PASTE_TTL_SECONDS)
    await flow.begin()
    assert await flow.authorize_url() is None
    waiting = asyncio.ensure_future(flow.wait())
    await asyncio.sleep(0)
    flow.cancel()
    assert await waiting is False


@pytest.mark.asyncio
async def test_not_authenticated_raises_a_typed_frame_and_the_app_sign_in_resolves_it(authorities, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)
    monkeypatch.setattr(gw, 'finish_signin', lambda flow_id, pasted: {'state': 'signed_in', 'status': None})
    retried = []

    def retry():
        retried.append(1)
        return json.dumps({'output': '[]', 'exit_code': 0})

    task = asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve('terminal', COMMAND, FAILING, retry)))
    await _wait_for(lambda: len(phone.events('auth.required')) == 1)
    event = phone.events('auth.required')[0]
    assert (event['service'], event['reason'], event['flow'], event['signin_on']) == (
        SERVICE, 'revoked', 'oauth_paste', 'owner_app')
    assert event['service_name'] == 'Google Workspace' and 'verification_uri' not in event
    callback = await phone.call('auth.submit_callback', {'request_id': event['request_id'], 'value': 'x'})
    assert callback['result']['outcome'] == 'rejected'
    assert (await _in_home(home, _finish_rpc))['result']['state'] == 'signed_in'
    assert json.loads(await task) == {'output': '[]', 'exit_code': 0}
    assert retried == [1]
    assert phone.events('auth.resolved') == [{'request_id': event['request_id'], 'outcome': 'signed_in'}]
    assert CANARY not in json.dumps(phone.frames) + caplog.text


@pytest.mark.asyncio
async def test_a_failed_app_sign_in_leaves_the_request_waiting(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)
    monkeypatch.setattr(gw, 'finish_signin', lambda flow_id, pasted: {'state': 'retry', 'status': None})
    task = asyncio.ensure_future(_in_home(home, lambda: auth_required.resolve('terminal', COMMAND, FAILING, lambda: None)))
    await _wait_for(lambda: len(phone.events('auth.required')) == 1)
    assert (await _in_home(home, _finish_rpc))['result']['state'] == 'retry'
    assert not task.done() and phone.events('auth.resolved') == []
    request_id = phone.events('auth.required')[0]['request_id']
    await phone.call('auth.decline', {'request_id': request_id})
    assert json.loads(await task)['error_type'] == 'auth_declined'


@pytest.mark.asyncio
async def test_signed_in_with_no_waiting_request_is_a_no_op(authorities, monkeypatch):
    authority = await authorities('home')
    monkeypatch.setattr(gw, 'finish_signin', lambda flow_id, pasted: {'state': 'signed_in', 'status': None})
    assert (await _in_home(home_of(authority), _finish_rpc))['result']['state'] == 'signed_in'
