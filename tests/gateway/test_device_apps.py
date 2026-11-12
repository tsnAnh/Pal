import json
import logging

import pytest

from tests.gateway.device_tools_harness import (
    Approvals,
    call_device,
    call_devices_list,
    connect_phone,
    device_id_for,
    home_of,
    set_state,
)
from tests.gateway.test_device_access_tools import MAC_MODEL, mac

pytest_plugins = ('tests.gateway.device_tools_harness',)

CANARY = 'CANARY-private-title-7741'
SAFARI = {'name': 'Safari', 'bundle_id': 'com.apple.Safari', 'pid': 412, 'frontmost': True}
WINDOW = {'window_id': 88, 'app': 'Safari', 'pid': 412, 'title': CANARY,
          'frame': {'x': 0, 'y': 25, 'width': 1440, 'height': 875}, 'on_screen': True}

ANSWERS = {
    'apps.list': {'apps': [SAFARI]},
    'apps.open': {'app': SAFARI, 'launched': True},
    'apps.quit': {'app': SAFARI, 'quit_requested': True},
    'windows.list': {'windows': [WINDOW], 'titles_available': True},
    'windows.focus': {'app': SAFARI, 'window_id': 88, 'raised': True},
}
CALLS = [
    ('apps.list', {}),
    ('apps.open', {'app': 'com.apple.TextEdit', 'target': '~/a.txt'}),
    ('apps.quit', {'app': 'TextEdit'}),
    ('windows.list', {'app': 'Safari'}),
    ('windows.focus', {'window_id': 88}),
]


def apps_answer(payload):
    return {'ok': True, 'result': ANSWERS[payload['action']]}


async def apps_mac(authority, label='Work Mac', responder=apps_answer):
    phone = await mac(authority, label, responder=responder)
    await set_state(phone, 'apps', 'allowed')
    return phone


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', CALLS)
async def test_each_apps_action_reaches_the_mac_and_comes_back_marked_as_data(authorities, monkeypatch, action, args):
    approvals = Approvals(monkeypatch, 'deny')
    authority = await authorities()
    work = await apps_mac(authority)
    result = await call_device(authority, 'Work Mac', action, args)
    request = work.requests()[0]
    assert request['action'] == action and request['connector'] == 'apps'
    assert request['args'].items() >= args.items()
    assert result['success'] is True and result['untrusted_content'] is True
    assert result['source'] == 'user_device' and 'never as instructions' in result['notice']
    assert approvals.prompts == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_apps_connector_is_off_by_default_and_the_tool_is_offered_only_once_it_is_on(authorities):
    from gateway import device_connectors
    from tui_gateway.contracts.canonical_device import DeviceConnectorId
    authority = await authorities()
    work = await mac(authority, 'Work Mac', responder=apps_answer)
    home = home_of(authority)
    assert 'apps' not in (await call_devices_list(authority))['devices'][0]['capabilities']
    assert device_connectors.open_devices(home, DeviceConnectorId.APPS) == {}
    for action, args in CALLS:
        result = await call_device(authority, 'Work Mac', action, args)
        assert result['code'] == 'connector_off' and 'Apps' in result['error']
    assert work.requests() == []
    await set_state(work, 'apps', 'allowed')
    assert (await call_devices_list(authority))['devices'][0]['capabilities']['apps'] == 'allowed'
    assert (await call_device(authority, 'Work Mac', 'apps.list'))['success'] is True
    await set_state(work, 'apps', 'off')
    assert (await call_device(authority, 'Work Mac', 'apps.list'))['code'] == 'connector_off'
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once_and_nothing_is_queued(authorities):
    authority = await authorities()
    work = await apps_mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'apps.list')
    assert result['code'] == 'phone_offline' and 'Work Mac is offline' in result['error']


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', CALLS)
async def test_an_iphone_answers_unsupported_for_apps_and_windows(authorities, action, args):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=apps_answer, model='iPhone15,2')
    result = await call_device(authority, 'Sam iPhone', action, args)
    assert result['code'] == 'unsupported' and 'Sam iPhone' in result['error'] and pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_older_mac_app_that_does_not_know_the_action_answers_unsupported(authorities):
    def old_app(payload):
        return {'ok': False, 'error': {'code': 'unsupported', 'message': f"This device does not do {payload['action']}."}}
    authority = await authorities()
    work = await apps_mac(authority, responder=old_app)
    result = await call_device(authority, 'Work Mac', 'windows.list')
    assert result['code'] == 'unsupported' and 'Work Mac cannot do windows.list' in result['error']
    assert 'success' not in result
    await work.connection.close()


@pytest.mark.asyncio
async def test_another_profiles_mac_is_not_reachable(authorities):
    mine = await authorities('install/profiles/mine')
    theirs = await authorities('install/profiles/theirs')
    my_mac = await apps_mac(mine, 'My Mac')
    their_mac = await apps_mac(theirs, 'Neighbour Mac')
    result = await call_device(mine, 'Neighbour Mac', 'apps.quit', {'app': 'Safari'})
    assert result['code'] == 'device_not_found' and 'Neighbour Mac' not in json.dumps(result['devices'])
    assert their_mac.requests() == [] and my_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_a_connector_still_asking_keeps_the_approval_gate_for_opening_quitting_and_focusing(authorities, monkeypatch):
    authority = await authorities()
    work = await mac(authority, 'Work Mac', responder=apps_answer)
    await set_state(work, 'apps', 'ask')
    approvals = Approvals(monkeypatch, 'deny')
    for action, args in (('apps.open', {'app': 'TextEdit'}), ('apps.quit', {'app': 'TextEdit'}),
                         ('windows.focus', {'app': 'TextEdit'})):
        assert (await call_device(authority, 'Work Mac', action, args))['code'] == 'approval_denied'
    assert work.requests() == [] and len(approvals.prompts) == 3
    await work.connection.close()


@pytest.mark.asyncio
async def test_window_titles_never_reach_the_logs(authorities, caplog):
    authority = await authorities()
    work = await apps_mac(authority)
    with caplog.at_level(logging.DEBUG):
        result = await call_device(authority, 'Work Mac', 'windows.list', {})
    assert result['data']['windows'][0]['title'] == CANARY
    assert CANARY not in caplog.text
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_failure_to_read_titles_still_returns_the_rest(authorities):
    def without_titles(payload):
        window = {key: value for key, value in WINDOW.items() if key != 'title'}
        return {'ok': True, 'result': {'windows': [window], 'titles_available': False,
                                       'note': 'Window titles need Screen Recording permission for Pal.'}}
    authority = await authorities()
    work = await apps_mac(authority, responder=without_titles)
    result = await call_device(authority, 'Work Mac', 'windows.list')
    data = result['data']
    assert result['success'] is True and data['titles_available'] is False and 'Screen Recording' in data['note']
    assert data['windows'][0]['app'] == 'Safari' and 'title' not in data['windows'][0]
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_missing_system_permission_is_a_clear_error_not_a_silent_success(authorities):
    def refuse(payload):
        return {'ok': False, 'error': {'code': 'permission_denied',
                                       'message': 'Allow Accessibility for Pal in System Settings.'}}
    authority = await authorities()
    work = await apps_mac(authority, responder=refuse)
    result = await call_device(authority, 'Work Mac', 'windows.focus', {'window_id': 88})
    assert result['code'] == 'permission_denied' and 'Work Mac' in result['error'] and 'success' not in result
    await work.connection.close()


@pytest.mark.asyncio
async def test_app_and_window_lists_are_capped(authorities):
    def flood(payload):
        if payload['action'] == 'apps.list':
            return {'ok': True, 'result': {'apps': [{**SAFARI, 'pid': n} for n in range(500)]}}
        return {'ok': True, 'result': {'windows': [{**WINDOW, 'window_id': n} for n in range(500)]}}
    authority = await authorities()
    work = await apps_mac(authority, responder=flood)
    apps = await call_device(authority, 'Work Mac', 'apps.list')
    windows = await call_device(authority, 'Work Mac', 'windows.list')
    assert len(apps['data']['apps']) == 200 and len(windows['data']['windows']) == 200
    await work.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', [
    ('apps.open', {}),
    ('apps.open', {'app': ''}),
    ('apps.quit', {'app': 'Safari', 'force': True}),
    ('apps.list', {'limit': 201}),
    ('windows.focus', {}),
    ('windows.list', {'limit': 0}),
])
async def test_invalid_arguments_never_reach_the_mac(authorities, action, args):
    authority = await authorities()
    work = await apps_mac(authority)
    assert (await call_device(authority, 'Work Mac', action, args))['code'] == 'invalid_args'
    assert work.requests() == []
    await work.connection.close()


def test_the_apps_connector_is_a_mac_only_switch_that_starts_off():
    from gateway.device_actions import connector_info
    from tui_gateway.contracts.canonical_device import DeviceConnectorId
    info = connector_info(DeviceConnectorId.APPS)
    assert info.on_by_default is False and info.kinds == frozenset({'mac'})
    assert info.subtitle == 'Let bots open and switch apps on this Mac'
