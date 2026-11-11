import asyncio
import json
import logging
from pathlib import Path

import pytest

from gateway import auth_flows, auth_prompts
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tests.gateway.device_tools_harness import connect_phone, home_of
from tools import auth_required
from tools.auth_required import AuthNeed

pytest_plugins = ('tests.gateway.device_tools_harness',)

SECRET = 'fake-token-9f3a1c77d2'


class FakeFlow:
    kind = 'device_code'
    user_code = 'ABCD-1234'
    verification_uri = 'https://example.com/device'
    expires_in = 900
    instances: list = []

    def __init__(self, home=None, service=None):
        self.signed_in = asyncio.Event()
        self.result = True
        self.cancelled = False
        self._token = SECRET
        FakeFlow.instances.append(self)

    async def begin(self):
        return None

    async def authorize_url(self):
        return None

    async def wait(self):
        await self.signed_in.wait()
        return self.result

    def cancel(self):
        self.cancelled = True
        self.signed_in.set()


class FakeOAuthFlow(FakeFlow):
    kind = 'oauth'
    user_code = None
    verification_uri = None
    expires_in = None

    async def authorize_url(self):
        return 'https://example.com/authorize?state=abc'


@pytest.fixture(autouse=True)
def fake_service():
    FakeFlow.instances = []
    auth_flows.register('fakesvc', FakeFlow)
    auth_flows.register('fakeoauth', FakeOAuthFlow)
    yield
    auth_flows.unregister('fakesvc')
    auth_flows.unregister('fakeoauth')
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


async def _phone(authorities):
    authority = await authorities('home')
    return authority, await connect_phone(authority)


async def _wait_for(predicate, timeout=5.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        assert asyncio.get_running_loop().time() < deadline, 'condition not reached'
        await asyncio.sleep(0.02)


def _in_home(home: Path, fn):
    def run():
        token = set_hermes_home_override(home)
        try:
            return fn()
        finally:
            reset_hermes_home_override(token)
    return asyncio.to_thread(run)


def _unauthorized(service='fakesvc'):
    return auth_required.http_auth_failure(service, 401)


async def _call(home, service='fakesvc', retry=None, first=None):
    retried = []

    def retry_default():
        retried.append(1)
        return json.dumps({'ok': True})

    fn = retry or retry_default
    result = await _in_home(home, lambda: auth_required.resolve('fake_tool', {}, first or _unauthorized(service), fn))
    return result, retried


async def _call_result(*args, **kwargs):
    return (await _call(*args, **kwargs))[0]


def _required(phone):
    return phone.events('auth.required')


@pytest.mark.asyncio
async def test_401_raises_one_event_and_signin_retries_the_call(authorities, caplog):
    caplog.set_level(logging.DEBUG)
    authority, phone = await _phone(authorities)
    task = asyncio.ensure_future(_call_result(home_of(authority)))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['service'] == 'fakesvc' and event['reason'] == 'expired' and event['flow'] == 'device_code'
    assert event['user_code'] == 'ABCD-1234' and event['bots'] == ['default']
    assert (await phone.call('auth.signin', {'request_id': event['request_id']}))['result']['recorded'] is True
    FakeFlow.instances[0].signed_in.set()
    result = json.loads(await task)
    assert result == {'ok': True}
    resolved = phone.events('auth.resolved')
    assert resolved == [{'request_id': event['request_id'], 'outcome': 'signed_in'}]
    blob = json.dumps(phone.frames) + json.dumps(result) + caplog.text
    assert SECRET not in blob


@pytest.mark.asyncio
async def test_retry_runs_once_and_a_second_auth_failure_raises_no_second_dialog(authorities):
    authority, phone = await _phone(authorities)
    retries = []

    def still_unauthorized():
        retries.append(1)
        return _unauthorized()

    task = asyncio.ensure_future(_call_result(home_of(authority), retry=still_unauthorized))
    await _wait_for(lambda: len(_required(phone)) == 1)
    FakeFlow.instances[0].signed_in.set()
    result = json.loads(await task)
    assert retries == [1]
    assert result['error_type'] == 'auth_failed'
    assert len(_required(phone)) == 1
    assert len(FakeFlow.instances) == 1


@pytest.mark.asyncio
async def test_not_now_returns_user_declined_and_the_bot_stops(authorities):
    authority, phone = await _phone(authorities)
    task = asyncio.ensure_future(_call(home_of(authority)))
    await _wait_for(lambda: len(_required(phone)) == 1)
    request_id = _required(phone)[0]['request_id']
    assert (await phone.call('auth.decline', {'request_id': request_id}))['result']['recorded'] is True
    result, retried = await task
    body = json.loads(result)
    assert body['error_type'] == 'auth_declined' and 'declined sign-in' in body['error'] and retried == []
    assert phone.events('auth.resolved')[-1]['outcome'] == 'declined'
    again, _ = await _call(home_of(authority))
    assert json.loads(again)['error_type'] == 'auth_declined'
    assert len(_required(phone)) == 1


@pytest.mark.asyncio
async def test_events_for_one_service_collapse_into_one_request(authorities):
    authority, phone = await _phone(authorities)
    home = home_of(authority)
    need = AuthNeed('fakesvc', 'missing')
    first = asyncio.ensure_future(asyncio.to_thread(auth_prompts.call_from_thread, home, need, 'alpha'))
    await _wait_for(lambda: len(_required(phone)) == 1)
    second = asyncio.ensure_future(asyncio.to_thread(auth_prompts.call_from_thread, home, need, 'beta'))
    await _wait_for(lambda: len(_required(phone)) == 2)
    events = _required(phone)
    assert events[0]['request_id'] == events[1]['request_id']
    assert events[1]['bots'] == ['alpha', 'beta'] and len(FakeFlow.instances) == 1
    FakeFlow.instances[0].signed_in.set()
    assert await first is auth_prompts.Resolution.SIGNED_IN
    assert await second is auth_prompts.Resolution.SIGNED_IN


@pytest.mark.asyncio
async def test_unanswered_signin_times_out(authorities, monkeypatch):
    monkeypatch.setattr(auth_prompts, 'SIGNIN_TIMEOUT_SECONDS', 0.3)
    authority, phone = await _phone(authorities)
    result, retried = await _call(home_of(authority))
    body = json.loads(result)
    assert body['error_type'] == 'auth_timeout' and 'timed out' in body['error'] and retried == []
    assert phone.events('auth.resolved')[-1]['outcome'] == 'timed_out'
    assert FakeFlow.instances[0].cancelled


@pytest.mark.asyncio
async def test_no_connected_app_fails_fast_with_a_plain_message(authorities):
    authority = await authorities('home')
    result, retried = await asyncio.wait_for(_call(home_of(authority)), 3)
    body = json.loads(result)
    assert body['error_type'] == 'auth_no_app' and retried == []
    assert 'Fakesvc' in body['error'] and 'no Pal app connected' in body['error']
    assert FakeFlow.instances == []


@pytest.mark.asyncio
async def test_a_phone_that_cannot_take_the_event_counts_as_no_app(authorities):
    authority, phone = await _phone(authorities)
    phone.accept_writes = False
    result, _ = await asyncio.wait_for(_call(home_of(authority)), 3)
    assert json.loads(result)['error_type'] == 'auth_no_app'
    assert auth_prompts._active == {}


@pytest.mark.asyncio
async def test_oauth_flow_returns_the_authorization_url_to_open_in_the_system_browser(authorities):
    authority, phone = await _phone(authorities)
    task = asyncio.ensure_future(_call_result(home_of(authority), service='fakeoauth'))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['flow'] == 'oauth' and 'user_code' not in event
    reply = await phone.call('auth.signin', {'request_id': event['request_id']})
    assert reply['result'] == {'recorded': True, 'authorization_url': 'https://example.com/authorize?state=abc'}
    FakeFlow.instances[0].signed_in.set()
    assert json.loads(await task) == {'ok': True}


@pytest.mark.asyncio
async def test_another_users_connection_cannot_answer_the_request(authorities):
    authority, phone = await _phone(authorities)
    stranger = await connect_phone(await authorities('other'), label='iPad')
    task = asyncio.ensure_future(_call(home_of(authority)))
    await _wait_for(lambda: len(_required(phone)) == 1)
    request_id = _required(phone)[0]['request_id']
    assert stranger.frames == [] or not [f for f in stranger.frames if f['params']['type'].startswith('auth.')]
    assert (await stranger.call('auth.decline', {'request_id': request_id}))['result']['recorded'] is False
    assert (await stranger.call('auth.signin', {'request_id': request_id}))['result']['recorded'] is False
    await phone.call('auth.decline', {'request_id': request_id})
    await task


@pytest.mark.asyncio
async def test_unconfigured_github_falls_back_to_a_manual_dialog(authorities):
    authority, phone = await _phone(authorities)
    task = asyncio.ensure_future(asyncio.to_thread(
        auth_prompts.call_from_thread, home_of(authority), AuthNeed('github', 'missing'), 'default'))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['flow'] == 'manual' and event['service_name'] == 'GitHub'
    await phone.call('auth.decline', {'request_id': event['request_id']})
    assert await task is auth_prompts.Resolution.DECLINED


@pytest.mark.asyncio
async def test_a_tool_call_through_the_dispatcher_is_retried_after_sign_in(authorities):
    from model_tools import handle_function_call
    from tools.registry import registry
    authority, phone = await _phone(authorities)
    calls = []

    def handler(args, **kwargs):
        calls.append(1)
        return _unauthorized() if len(calls) == 1 else json.dumps({'ok': 'second'})

    registry.register(name='fake_auth_tool', toolset='fake_auth', schema={
        'name': 'fake_auth_tool', 'description': 'x', 'parameters': {'type': 'object', 'properties': {}}},
        handler=handler)
    try:
        home = home_of(authority)
        task = asyncio.ensure_future(_in_home(home, lambda: handle_function_call('fake_auth_tool', {}, task_id='t')))
        await _wait_for(lambda: len(_required(phone)) == 1)
        FakeFlow.instances[0].signed_in.set()
        assert json.loads(await task) == {'ok': 'second'}
        assert len(calls) == 2
    finally:
        registry.deregister('fake_auth_tool')


GH_NOT_LOGGED_IN = 'You are not logged into any GitHub hosts. To get started with GitHub CLI, please run:  gh auth login'


@pytest.mark.parametrize('command,output,code,reason', [
    ('gh pr list', GH_NOT_LOGGED_IN, 4, 'missing'),
    ('GH_PAGER=cat gh pr merge 3', 'HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login', 1, 'expired'),
    ('gh api user', 'gh: authentication required', 4, 'missing'),
    ('gh api user', 'your token has been revoked\nTry authenticating with:  gh auth login', 1, 'revoked'),
])
def test_gh_matcher_positive(command, output, code, reason):
    need = auth_required.match_gh_failure(command, output, code)
    assert need == AuthNeed('github', reason, flow='device_code')


@pytest.mark.parametrize('command,output,code', [
    ('gh pr list', GH_NOT_LOGGED_IN, 0),
    ('echo "gh auth login"', 'gh auth login', 1),
    ('cat notes.txt', GH_NOT_LOGGED_IN, 1),
    ('git push', 'remote: Authentication required', 1),
    ('gh pr list', 'no pull requests match your search', 1),
    ('gh pr view 9', 'HTTP 404: Not Found', 1),
    ('grep -r "not logged in" .', 'x.py: not logged in', 1),
    ('gh pr list', GH_NOT_LOGGED_IN, None),
])
def test_gh_matcher_negative(command, output, code):
    assert auth_required.match_gh_failure(command, output, code) is None


def test_detect_reads_the_typed_result_and_the_mcp_marker_not_free_text():
    assert auth_required.detect('t', {}, _unauthorized('x')) == AuthNeed('x', 'expired', None)
    mcp = json.dumps({'error': 'x', 'needs_reauth': True, 'server': 'notes'})
    assert auth_required.detect('mcp_notes_search', {}, mcp) == AuthNeed('mcp:notes', 'expired', 'oauth')
    assert auth_required.detect('t', {}, json.dumps({'error': 'HTTP 401 not logged in'})) is None
    terminal = json.dumps({'output': GH_NOT_LOGGED_IN, 'exit_code': 4, 'error': None})
    assert auth_required.detect('terminal', {'command': 'gh repo list'}, terminal).service == 'github'
    assert auth_required.detect('web_search', {'command': 'gh repo list'}, terminal) is None


def test_github_device_flow_polls_then_hands_the_token_to_gh_on_stdin_only():
    from hermes_cli import github_device_flow as flow
    answers = iter([{'error': 'authorization_pending'}, {'error': 'slow_down'}, {'access_token': SECRET}])
    sleeps = []
    code = flow.DeviceCode('dev', 'ABCD-1234', 'https://github.com/login/device', 900, 5)
    token = flow.poll_for_token('cid', code, post=lambda url, form: next(answers), sleep=sleeps.append)
    assert token == SECRET and sleeps == [5, 10]
    seen = {}

    def run(argv, **kwargs):
        seen.update(argv=argv, **kwargs)
        return type('R', (), {'returncode': 0})()

    flow.store_token_with_gh(token, run=run)
    assert seen['input'] == SECRET and SECRET not in ' '.join(seen['argv'])


@pytest.mark.parametrize('error', ['access_denied', 'expired_token'])
def test_github_device_flow_stops_on_a_terminal_error(error):
    from hermes_cli import github_device_flow as flow
    code = flow.DeviceCode('dev', 'U', 'https://github.com/login/device', 900, 1)
    with pytest.raises(flow.GithubSigninError) as raised:
        flow.poll_for_token('cid', code, post=lambda url, form: {'error': error}, sleep=lambda s: None)
    assert SECRET not in str(raised.value)


def test_github_client_id_comes_from_config_and_is_required(tmp_path):
    from hermes_cli import github_device_flow as flow
    with pytest.raises(flow.NotConfigured):
        flow.configured_client_id(tmp_path)
    (tmp_path / 'config.yaml').write_text('auth:\n  github:\n    client_id: Iv1.example\n')
    assert flow.configured_client_id(tmp_path) == 'Iv1.example'
