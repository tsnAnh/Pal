import asyncio
import json
import time

import pytest

from gateway import auth_prompts
from tests.gateway.device_tools_harness import call_device, connect_phone, device_id_for, home_of, set_state
from tests.waiting import async_wait_until

pytest_plugins = ('tests.gateway.device_tools_harness',)

MAC_MODEL = 'MacBookPro18,3'
CANARY = 'canary-pw-7d41e0'
PAGE = {'url': 'https://example.com/docs', 'title': 'Docs', 'text': 'Welcome back, Sam.'}


def page_answer(payload):
    assert payload['connector'] == 'browser'
    if payload['action'] == 'browser.close':
        return {'ok': True, 'result': {'closed': True}}
    return {'ok': True, 'result': dict(PAGE)}


async def browsing_mac(authority, label='Work Mac', responder=page_answer, *, on=True):
    phone = await connect_phone(authority, label, kind='mac', model=MAC_MODEL, responder=responder)
    if on:
        await set_state(phone, 'browser', 'allowed')
    return phone


@pytest.fixture(autouse=True)
def public_dns(monkeypatch):
    from tools import url_safety

    def resolve(hostname, port=None):
        address = '127.0.0.1' if hostname == 'localhost' else '93.184.216.34'
        return [(2, 1, 6, '', (address, port or 0))]
    monkeypatch.setattr(url_safety, '_getaddrinfo', resolve)


@pytest.fixture(autouse=True)
def reset_auth():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


@pytest.mark.asyncio
async def test_a_bot_opens_a_page_on_the_named_mac_and_gets_its_text(authorities):
    authority = await authorities()
    work = await browsing_mac(authority)
    result = await call_device(authority, 'work mac', 'browser.open', {'url': 'https://example.com/docs'})
    assert result['success'] is True and result['data']['text'] == 'Welcome back, Sam.'
    assert result['data']['title'] == 'Docs' and result['device']['name'] == 'Work Mac'
    request = work.requests()[0]
    assert request['action'] == 'browser.open' and request['connector'] == 'browser'
    assert request['args'] == {'url': 'https://example.com/docs'} and request['needs_consent'] is False
    read = await call_device(authority, 'Work Mac', 'browser.read')
    assert read['success'] is True and read['untrusted_content'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_click_type_wait_and_close_reach_the_mac(authorities):
    authority = await authorities()
    work = await browsing_mac(authority)
    calls = [('browser.click', {'text': 'Next'}), ('browser.type', {'selector': '#search', 'text': 'invoices'}),
             ('browser.wait_for_text', {'text': 'Results', 'timeout_seconds': 5}), ('browser.close', None)]
    for action, args in calls:
        assert (await call_device(authority, 'Work Mac', action, args))['success'] is True
    assert [r['action'] for r in work.requests()] == [c[0] for c in calls]
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_browser_is_off_until_the_mac_itself_switches_it_on(authorities):
    authority = await authorities()
    work = await browsing_mac(authority, on=False)
    result = await call_device(authority, 'Work Mac', 'browser.open', {'url': 'https://example.com'})
    assert result['code'] == 'connector_off' and 'Browser connector is off on Work Mac' in result['error']
    assert work.requests() == []
    listed = await call_device(authority, 'Work Mac', 'browser.read')
    assert listed['code'] == 'connector_off'
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once_and_nothing_is_queued(authorities):
    authority = await authorities()
    work = await browsing_mac(authority)
    await work.connection.close()
    started = time.monotonic()
    result = await call_device(authority, 'Work Mac', 'browser.open', {'url': 'https://example.com'})
    assert result['code'] == 'phone_offline' and 'Work Mac is offline, last seen' in result['error']
    assert time.monotonic() - started < 2.0
    again = await browsing_mac(authority)
    assert again.requests() == []
    await again.connection.close()


@pytest.mark.asyncio
async def test_an_unknown_or_ambiguous_device_fails_before_anything_is_sent(authorities):
    from gateway import device_connectors, device_registry
    authority = await authorities()
    work = await browsing_mac(authority, 'Mac')
    missing = await call_device(authority, 'Kitchen iPad', 'browser.open', {'url': 'https://example.com'})
    assert missing['code'] == 'device_not_found' and 'Mac' in missing['error']
    root = device_registry.install_root(authority.profile_id)
    device_registry.record_hello(root, device_id='second-mac-001', kind='mac', label='Mac', model='', os_name='',
                                 app_version='1', now=time.time())
    device_connectors.register_device(home_of(authority), 'second-mac-001', 'Mac', kind='mac')
    ambiguous = await call_device(authority, 'Mac', 'browser.open', {'url': 'https://example.com'})
    assert ambiguous['code'] == 'ambiguous_device' and len(ambiguous['devices']) == 2
    assert work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_iphone_asked_to_browse_is_unsupported(authorities):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2', responder=page_answer)
    result = await call_device(authority, 'Sam iPhone', 'browser.open', {'url': 'https://example.com'})
    assert result['code'] == 'unsupported' and 'browser' in result['error'] and pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_a_password_field_is_refused_and_the_text_never_leaves_the_gateway(authorities):
    authority = await authorities()
    work = await browsing_mac(authority)
    for selector in ('input[type=password]', '#Password', 'input[name="passcode"]'):
        result = await call_device(authority, 'Work Mac', 'browser.type', {'selector': selector, 'text': CANARY})
        assert result['code'] == 'invalid_args' and 'password' in result['error'] and CANARY not in json.dumps(result)
    assert work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_password_field_the_device_recognises_is_refused_without_echoing_the_text(authorities):
    def refuse(payload):
        return {'ok': False, 'error': {'code': 'invalid_args', 'message': 'That is a password field.'}}
    authority = await authorities()
    work = await browsing_mac(authority, responder=refuse)
    result = await call_device(authority, 'Work Mac', 'browser.type', {'selector': '#field-7', 'text': CANARY})
    assert result['code'] == 'invalid_args' and 'success' not in result and CANARY not in json.dumps(result)
    await work.connection.close()


@pytest.mark.parametrize('url', ['file:///etc/passwd', 'chrome://settings', 'about:blank', 'javascript:alert(1)',
                                 'http://169.254.169.254/latest/meta-data', 'http://localhost:8080/admin',
                                 'https://example.com/?api_key=sk-abcdefghijklmnopqrstuvwx'])
@pytest.mark.asyncio
async def test_urls_the_browser_policy_refuses_never_reach_the_mac(authorities, url):
    authority = await authorities()
    work = await browsing_mac(authority)
    result = await call_device(authority, 'Work Mac', 'browser.open', {'url': url})
    assert result['code'] == 'invalid_args' and 'success' not in result and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_redirect_to_a_blocked_page_returns_no_page_text(authorities):
    def redirected(payload):
        return {'ok': True, 'result': {'url': 'file:///Users/sam/secret.txt', 'title': 'x', 'text': 'private'}}
    authority = await authorities()
    work = await browsing_mac(authority, responder=redirected)
    result = await call_device(authority, 'Work Mac', 'browser.open', {'url': 'https://example.com/go'})
    assert result['code'] == 'blocked' and 'private' not in json.dumps(result)
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_login_page_raises_the_manual_sign_in_event_and_never_asks_for_a_password(authorities):
    def login(payload):
        return {'ok': True, 'result': {'url': 'https://accounts.example.com/login', 'title': 'Sign in',
                                       'text': 'Email Password', 'login_required': True}}
    authority = await authorities()
    work = await browsing_mac(authority, responder=login)
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'browser.open',
                                           {'url': 'https://accounts.example.com/login'}))
    await async_wait_until(lambda: work.events('auth.required'), timeout=5)
    event = work.events('auth.required')[0]
    assert event['service'] == 'site:accounts.example.com' and event['flow'] == 'manual'
    assert CANARY not in json.dumps(work.frames)
    await work.call('auth.decline', {'request_id': event['request_id']})
    result = await call
    assert result['error_type'] == 'auth_declined' and 'success' not in result
    assert len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_after_the_user_confirms_the_sign_in_the_page_is_read_once_more(authorities):
    answers = iter([
        {'ok': True, 'result': {'url': 'https://app.example.com/login', 'title': 'Sign in', 'text': 'Password',
                                'login_required': True}},
        {'ok': True, 'result': {'url': 'https://app.example.com/inbox', 'title': 'Inbox', 'text': 'Three new'}},
    ])
    authority = await authorities()
    work = await browsing_mac(authority, responder=lambda payload: next(answers))
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'browser.read'))
    await async_wait_until(lambda: work.events('auth.required'), timeout=5)
    event = work.events('auth.required')[0]
    assert event['flow'] == 'manual' and event['service_name']
    reply = await work.call('auth.signin', {'request_id': event['request_id']})
    assert reply['result']['recorded'] is True
    result = await call
    assert result['success'] is True and result['data']['text'] == 'Three new'
    assert len(work.requests()) == 2
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_login_page_that_is_still_a_login_page_after_confirming_is_not_retried_again(authorities):
    def login(payload):
        return {'ok': True, 'result': {'url': 'https://app.example.com/login', 'title': 'Sign in', 'text': 'Password',
                                       'login_required': True}}
    authority = await authorities()
    work = await browsing_mac(authority, responder=login)
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'browser.read'))
    await async_wait_until(lambda: work.events('auth.required'), timeout=5)
    await work.call('auth.signin', {'request_id': work.events('auth.required')[0]['request_id']})
    result = await call
    assert result['error_type'] == 'auth_failed' and 'success' not in result and len(work.requests()) == 2
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_page_over_the_cap_is_truncated_with_a_marker(authorities):
    from gateway import device_tools

    def huge(payload):
        return {'ok': True, 'result': {'url': 'https://example.com/long', 'title': 'Long', 'text': 'word ' * 200_000}}
    authority = await authorities()
    work = await browsing_mac(authority, responder=huge)
    result = await call_device(authority, 'Work Mac', 'browser.read')
    data = result['data']
    assert result['success'] is True and data['truncated'] is True and 'truncated' in data['text']
    assert len(json.dumps(data, ensure_ascii=False)) <= device_tools.MAX_RESULT_BYTES
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_mac_that_drops_mid_action_is_a_failure_with_an_unknown_effect(authorities):
    authority = await authorities()
    work = await browsing_mac(authority, responder=None)
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'browser.click', {'text': 'Pay now'}))
    await async_wait_until(lambda: work.requests(), timeout=5)
    await work.connection.close()
    result = await call
    assert result['code'] == 'disconnected' and 'success' not in result
    assert 'went offline during the action; the result is unknown' in result['error']
    assert 'effect of browser.click is unknown' in result['error']


@pytest.mark.asyncio
async def test_the_tool_text_tells_the_bot_how_to_browse_on_a_device(authorities):
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from model_tools import get_tool_definitions
    authority = await authorities()
    work = await browsing_mac(authority)
    token = set_hermes_home_override(home_of(authority))
    try:
        defs = {d['function']['name']: d['function']
                for d in get_tool_definitions(enabled_toolsets=['iphone'], quiet_mode=True)}
    finally:
        reset_hermes_home_override(token)
    text = defs['device']['description']
    assert 'browser.open' in text and 'browser.type' in text and 'no screenshots' in text
    assert 'password' in text and device_id_for('Work Mac')
    await work.connection.close()
