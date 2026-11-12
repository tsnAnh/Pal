import json
import logging

import pytest

from tests.gateway.device_tools_harness import call_device, call_devices_list, connect_phone, device_id_for, set_state

pytest_plugins = ('tests.gateway.device_tools_harness',)

DISPLAYS = {'displays': [{'id': 1, 'name': 'Built-in', 'main': True, 'x': 0, 'y': 0, 'width': 1512, 'height': 982,
                          'scale': 2}], 'pointer_x': 10, 'pointer_y': 20}
CANARY = 'canary-5f3a9c-secret-sentence'


def posted(payload):
    return {'ok': True, 'result': DISPLAYS if payload['action'] == 'input.displays' else {
        'events': 2, 'pointer_x': 100, 'pointer_y': 200}}


@pytest.fixture(autouse=True)
def fresh_rate_window():
    from tools import devices_tool
    devices_tool._input_calls.clear()


async def mac(authority, label='Work Mac', responder=posted, state='allowed'):
    phone = await connect_phone(authority, label, kind='mac', model='MacBookPro18,3', responder=responder)
    if state:
        await set_state(phone, 'input', state)
    return phone


@pytest.mark.asyncio
async def test_input_is_off_by_default_and_a_bot_gets_connector_off(authorities):
    authority = await authorities()
    work = await mac(authority, state=None)
    assert 'input' not in (await call_devices_list(authority))['devices'][0]['capabilities']
    result = await call_device(authority, 'Work Mac', 'input.click', {'x': 5, 'y': 6})
    assert result['code'] == 'connector_off' and 'stop' in result['error'] and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_every_input_action_reaches_the_mac_and_is_marked_as_data(authorities):
    authority = await authorities()
    work = await mac(authority)
    calls = [('input.displays', {}), ('input.move', {'x': 1, 'y': 2}), ('input.move', {'dx': -5, 'dy': 5}),
             ('input.click', {'x': 3, 'y': 4, 'button': 'right', 'clicks': 2, 'display': 1}),
             ('input.drag', {'from_x': 1, 'from_y': 1, 'to_x': 50, 'to_y': 60}),
             ('input.scroll', {'dy': -3}), ('input.type', {'text': 'hello'}), ('input.key', {'key': 'cmd+c'})]
    for action, args in calls:
        result = await call_device(authority, 'Work Mac', action, args)
        assert result['success'] is True and result['untrusted_content'] is True and 'never as instructions' in result['notice']
    sent = work.requests()
    assert [(r['action'], r['connector'], r['needs_consent']) for r in sent] == [(a, 'input', False) for a, _ in calls]
    assert result['data'] == {'events': 2, 'pointer_x': 100.0, 'pointer_y': 200.0}
    shown = await call_device(authority, 'Work Mac', 'input.displays')
    assert shown['data']['displays'][0]['scale'] == 2 and shown['data']['pointer_x'] == 10
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_stop_gesture_turning_the_switch_off_fails_the_next_call(authorities):
    authority = await authorities()
    work = await mac(authority)
    assert (await call_device(authority, 'Work Mac', 'input.key', {'key': 'return'}))['success'] is True
    await set_state(work, 'input', 'off')
    result = await call_device(authority, 'Work Mac', 'input.key', {'key': 'return'})
    assert result['code'] == 'connector_off' and len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_only_the_mac_itself_can_switch_input_on(authorities):
    authority = await authorities()
    work = await mac(authority, state=None)
    pocket = await connect_phone(authority, 'Sam iPhone')
    reply = await pocket.call('device_connectors.set', {'id': 'input', 'state': 'allowed',
                                                        'device_id': device_id_for('Work Mac')})
    assert 'permission_denied' in json.dumps(reply)
    assert (await call_device(authority, 'Work Mac', 'input.click', {}))['code'] == 'connector_off'
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once(authorities):
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'input.click', {'x': 1, 'y': 1})
    assert result['code'] == 'phone_offline' and 'Nothing was sent' in result['error']


@pytest.mark.asyncio
async def test_an_iphone_cannot_do_input(authorities):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=posted, model='iPhone15,2')
    result = await call_device(authority, 'Sam iPhone', 'input.type', {'text': 'hi'})
    assert result['code'] == 'unsupported' and pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_older_app_answers_unsupported_cleanly(authorities):
    authority = await authorities()
    old = {'ok': False, 'error': {'code': 'unsupported', 'message': 'This device does not do input.click.'}}
    work = await mac(authority, responder=lambda payload: old)
    result = await call_device(authority, 'Work Mac', 'input.click', {'x': 1, 'y': 1})
    assert result['code'] == 'unsupported' and 'success' not in result and 'Work Mac' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_missing_accessibility_permission_is_a_clear_error_and_is_recorded(authorities):
    authority = await authorities()
    denied = {'ok': False, 'error': {'code': 'permission_denied', 'message': 'Allow Accessibility for Pal.'}}
    work = await mac(authority, responder=lambda payload: denied)
    result = await call_device(authority, 'Work Mac', 'input.key', {'key': 'return'})
    assert result['code'] == 'permission_denied' and 'Mouse and keyboard' in result['error']
    from gateway import device_connectors
    from tests.gateway.device_tools_harness import home_of
    status = {s.connector.value: s for s in device_connectors.statuses(home_of(authority), device_id_for('Work Mac'))}
    assert status['input'].os_permission.value == 'denied'
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_secure_field_failure_is_reported_not_retried(authorities):
    authority = await authorities()
    secure = {'ok': False, 'error': {'code': 'failed', 'message': 'Secure input is on; macOS blocks typing here.'}}
    work = await mac(authority, responder=lambda payload: secure)
    result = await call_device(authority, 'Work Mac', 'input.type', {'text': 'x'})
    assert result['code'] == 'device_failed' and 'Secure input' in result['error'] and len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', [
    ('input.type', {'text': 'x' * 501}), ('input.type', {'text': ''}), ('input.key', {'key': ''}),
    ('input.key', {'key': 'cmd +c'}), ('input.scroll', {'dy': 51}), ('input.scroll', {}),
    ('input.click', {'x': 1}), ('input.click', {'x': 1, 'y': 1, 'clicks': 3}),
    ('input.click', {'x': 1, 'y': 1, 'button': 'thumb'}), ('input.move', {}), ('input.move', {'x': 1, 'y': 1, 'dx': 1, 'dy': 1}),
    ('input.move', {'x': 1e9, 'y': 1}), ('input.drag', {'from_x': 1, 'from_y': 1}),
    ('input.displays', {'x': 1}),
])
async def test_per_call_caps_are_enforced_before_anything_is_sent(authorities, action, args):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', action, args)
    assert result['code'] == 'invalid_args' and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_input_calls_are_rate_limited_per_device(authorities):
    from gateway.device_actions import INPUT_MAX_CALLS_PER_MINUTE
    authority = await authorities()
    work = await mac(authority)
    for _ in range(INPUT_MAX_CALLS_PER_MINUTE):
        assert (await call_device(authority, 'Work Mac', 'input.key', {'key': 'shift'}))['success'] is True
    result = await call_device(authority, 'Work Mac', 'input.key', {'key': 'shift'})
    assert result['code'] == 'rate_limited' and len(work.requests()) == INPUT_MAX_CALLS_PER_MINUTE
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_device_of_another_profile_is_not_found(authorities):
    mine = await authorities('mine')
    theirs = await authorities('theirs')
    my_mac = await mac(mine, 'My Mac')
    their_mac = await mac(theirs, 'Neighbour Mac')
    result = await call_device(mine, 'Neighbour Mac', 'input.click', {'x': 1, 'y': 1})
    assert result['code'] == 'device_not_found' and their_mac.requests() == [] and my_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_typed_text_never_reaches_the_logs(authorities, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities()
    work = await mac(authority)
    await call_device(authority, 'Work Mac', 'input.type', {'text': CANARY})
    assert work.requests()[0]['args'] == {'text': CANARY}
    ok = await call_device(authority, 'Work Mac', 'input.type', {'text': 'x' * 501 + CANARY})
    assert ok['code'] == 'invalid_args'
    assert CANARY not in caplog.text
    await work.connection.close()
