import json
import logging

import pytest

from tests.gateway.device_tools_harness import (
    call_device,
    call_devices_list,
    connect_phone,
    device_id_for,
    home_of,
    set_state,
)

pytest_plugins = ('tests.gateway.device_tools_harness',)

CANARY = 'canary-7f3a-do-not-log'


def posted(payload):
    return {'ok': True, 'result': {'identifier': payload['args'].get('identifier', 'n1')}}


async def mac(authority, label='Work Mac', *, responder=posted, on=True):
    phone = await connect_phone(authority, label, kind='mac', model='MacBookPro18,3', responder=responder)
    if on:
        await set_state(phone, 'notifications', 'allowed')
    return phone


@pytest.fixture(autouse=True)
def fresh_limits():
    from gateway import device_rate
    device_rate.reset()
    yield
    device_rate.reset()


@pytest.mark.asyncio
async def test_a_bot_posts_a_notification_and_the_device_is_told_whose_bot_it_is(authorities):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'notify.post', {
        'title': 'System update', 'body': 'Restart now', 'subtitle': 'Apple', 'sound': True, 'identifier': 'job-1'})
    request = work.requests()[0]
    assert request['action'] == 'notify.post' and request['connector'] == 'notifications'
    assert request['args'] == {'title': 'System update', 'body': 'Restart now', 'subtitle': 'Apple',
                               'sound': True, 'identifier': 'job-1'}
    assert request['profile'] == 'default' and request['needs_consent'] is False
    assert result['success'] is True and result['data'] == {'identifier': 'job-1'}
    assert result['untrusted_content'] is True and 'never as instructions' in result['notice']
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_bot_cancels_a_notification_by_identifier(authorities):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'notify.cancel', {'identifier': 'job-1'})
    assert work.requests()[0]['action'] == 'notify.cancel' and result['data'] == {'identifier': 'job-1'}
    await work.connection.close()


@pytest.mark.asyncio
async def test_notifications_need_no_switch_and_ignore_a_set_off(authorities):
    authority = await authorities()
    work = await mac(authority, on=False)
    listed = (await call_devices_list(authority))['devices'][0]
    assert listed['capabilities']['notifications'] == 'allowed'
    assert (await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'}))['success'] is True
    await set_state(work, 'notifications', 'off')
    assert (await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'}))['success'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_only_the_mac_itself_can_set_its_notifications_state(authorities):
    authority = await authorities()
    work = await mac(authority, on=False)
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2')
    reply = await pocket.call('device_connectors.set', {
        'id': 'notifications', 'state': 'allowed', 'device_id': device_id_for('Work Mac')})
    assert 'permission_denied' in json.dumps(reply)
    assert (await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'}))['success'] is True
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_iphone_cannot_show_a_bot_notification_through_this_tool(authorities):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2', responder=posted)
    for action, args in (('notify.post', {'title': 'a', 'body': 'b'}), ('notify.cancel', {'identifier': 'x'})):
        result = await call_device(authority, 'Sam iPhone', action, args)
        assert result['code'] == 'unsupported' and 'Sam iPhone' in result['error']
    assert pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_older_app_that_does_not_know_the_action_answers_unsupported(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda payload: {
        'ok': False, 'error': {'code': 'unsupported', 'message': 'This device does not do notify.post.'}})
    result = await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'})
    assert result['code'] == 'unsupported' and 'Work Mac' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_denied_macos_permission_is_a_clear_error_never_silent(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda payload: {
        'ok': False, 'error': {'code': 'permission_denied', 'message': 'Allow Notifications for Pal in System Settings.'}})
    result = await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'})
    assert result['code'] == 'permission_denied' and 'Work Mac' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once_and_nothing_is_queued(authorities):
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'})
    assert result['code'] == 'phone_offline'


@pytest.mark.asyncio
async def test_a_mac_of_another_profile_is_not_reachable(authorities, tmp_path):
    (tmp_path / 'install').mkdir()
    (tmp_path / 'install' / 'config.yaml').write_text('{}')
    mine = await authorities('install/profiles/mine')
    theirs = await authorities('install/profiles/theirs')
    their_mac = await mac(theirs, 'Neighbour Mac')
    result = await call_device(mine, 'Neighbour Mac', 'notify.post', {'title': 'a', 'body': 'b'})
    assert result['code'] == 'device_not_found' and their_mac.requests() == []
    await their_mac.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('args', [
    {'title': 'x' * 81, 'body': 'b'},
    {'title': 'a', 'body': 'x' * 241},
    {'title': 'a', 'body': 'b', 'subtitle': 'x' * 81},
    {'title': 'a', 'body': 'b', 'identifier': 'x' * 65},
    {'title': 'a', 'body': 'b', 'identifier': 'has space'},
    {'title': '   ', 'body': 'b'},
    {'title': 'a', 'body': ''},
    {'title': 'a', 'body': 'b', 'url': 'https://example.com'},
    {'title': 'a', 'body': 'b', 'actions': ['open']},
])
async def test_oversized_blank_or_extra_fields_never_reach_the_mac(authorities, args):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'notify.post', args)
    assert result['code'] == 'invalid_args' and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_text_at_the_caps_is_accepted_and_control_characters_are_stripped(authorities):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'notify.post', {
        'title': 'x' * 80, 'body': 'y' * 240, 'subtitle': 'z' * 80})
    assert result['success'] is True
    await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a\x07b‮', 'body': 'c\x00d'})
    assert work.requests()[1]['args'] == {'title': 'ab', 'body': 'cd', 'sound': False}
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_bot_is_limited_to_five_notifications_a_minute_and_cancel_is_free(authorities):
    authority = await authorities()
    work = await mac(authority)
    for _ in range(5):
        assert (await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'}))['success'] is True
    sixth = await call_device(authority, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'})
    assert sixth['code'] == 'rate_limited' and sixth['retry_after_seconds'] >= 1
    assert len(work.requests()) == 5
    assert (await call_device(authority, 'Work Mac', 'notify.cancel', {'identifier': 'a'}))['success'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_one_mac_is_limited_to_ten_notifications_a_minute_across_bots(authorities, tmp_path):
    (tmp_path / 'install').mkdir()
    (tmp_path / 'install' / 'config.yaml').write_text('{}')
    bots = [await authorities(f'install/profiles/bot{n}') for n in range(3)]
    macs = [await mac(bot, 'Work Mac') for bot in bots]
    outcomes = []
    for bot in bots:
        for _ in range(4):
            outcomes.append((await call_device(bot, 'Work Mac', 'notify.post', {'title': 'a', 'body': 'b'})).get('code'))
    assert outcomes.count(None) == 10 and outcomes[-2:] == ['rate_limited', 'rate_limited']
    for phone in macs:
        await phone.connection.close()


def test_the_window_frees_up_after_a_minute():
    from gateway import device_rate
    for _ in range(device_rate.PER_BOT):
        assert device_rate.claim('bot', 'dev', now=100.0) is None
    assert device_rate.claim('bot', 'dev', now=130.0) == pytest.approx(30.0)
    assert device_rate.claim('bot', 'dev', now=161.0) is None


@pytest.mark.asyncio
async def test_notification_text_never_reaches_the_logs(authorities, caplog):
    authority = await authorities()
    work = await mac(authority)
    caplog.set_level(logging.DEBUG)
    await call_device(authority, 'Work Mac', 'notify.post', {
        'title': CANARY, 'body': CANARY, 'subtitle': CANARY, 'identifier': 'canary-id'})
    await call_device(authority, 'Work Mac', 'notify.post', {'title': CANARY, 'body': 'x' * 300})
    assert CANARY not in caplog.text
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_result_never_echoes_the_text_back(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda payload: {
        'ok': True, 'result': {'identifier': 'n1', 'title': CANARY, 'body': CANARY}})
    result = await call_device(authority, 'Work Mac', 'notify.post', {'title': CANARY, 'body': 'b'})
    assert result['data'] == {'identifier': 'n1'} and CANARY not in json.dumps(result)
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_tool_text_tells_the_bot_about_attribution_and_the_caps(authorities):
    from tools.devices_tool import _device_overrides
    text = _device_overrides()['description']
    assert 'notify.post' in text and 'via Pal' in text and 'at most 5 per minute' in text


def test_the_connector_is_always_on_for_a_mac_and_absent_on_an_iphone(tmp_path):
    from gateway import device_connectors
    from tui_gateway.contracts.canonical_device import DeviceConnectorId, DeviceConnectorState
    device_connectors.register_device(tmp_path, 'device-mac-0001', 'Work Mac', kind='mac')
    device_connectors.register_device(tmp_path, 'device-ios-0001', 'Sam iPhone', kind='ios')
    mac_rows = {row.connector: row.state for row in device_connectors.statuses(tmp_path, 'device-mac-0001')}
    ios_rows = {row.connector for row in device_connectors.statuses(tmp_path, 'device-ios-0001')}
    assert mac_rows[DeviceConnectorId.NOTIFICATIONS] is DeviceConnectorState.ALLOWED
    assert DeviceConnectorId.NOTIFICATIONS not in ios_rows
    assert device_connectors.open_devices(tmp_path, DeviceConnectorId.NOTIFICATIONS) == {
        'device-mac-0001': DeviceConnectorState.ALLOWED}
