import pytest

from tests.gateway.device_tools_harness import Approvals, call_iphone, connect_phone, set_state

pytest_plugins = ('tests.gateway.device_tools_harness',)

STORE: dict[str, dict] = {}


def eventkit_phone(payload):
    action, args = payload['action'], payload['args']
    if action == 'reminders.add':
        STORE['r1'] = {'id': 'r1', 'title': args['title'], 'completed': False, 'list': 'Reminders'}
        return {'ok': True, 'result': {'reminder': STORE['r1']}}
    if action == 'reminders.list':
        return {'ok': True, 'result': {'reminders': list(STORE.values())}}
    if action == 'reminders.complete':
        if args['reminder_id'] not in STORE:
            return {'ok': False, 'error': {'code': 'not_found'}}
        STORE[args['reminder_id']]['completed'] = True
        return {'ok': True, 'result': {'reminder': STORE[args['reminder_id']]}}
    raise AssertionError(action)


@pytest.fixture(autouse=True)
def fresh_store(monkeypatch):
    STORE.clear()
    Approvals(monkeypatch, 'once')


async def _reminders_on(authorities, label, kind, **kwargs):
    authority = await authorities(f'home-{label}')
    device = await connect_phone(authority, label, kind=kind, responder=eventkit_phone, **kwargs)
    await set_state(device, 'reminders', 'allowed')
    return authority, device


@pytest.mark.asyncio
@pytest.mark.parametrize('label,kind', [('iPhone', 'ios'), ('Mac', 'mac')])
async def test_a_bot_adds_lists_and_completes_a_reminder_on_the_device(authorities, label, kind):
    authority, device = await _reminders_on(authorities, label, kind)
    added = await call_iphone(authority, 'reminders.add', {'title': 'Buy milk'})
    assert added.get('success') is True, added
    listed = await call_iphone(authority, 'reminders.list')
    assert [r['title'] for r in listed['data']['reminders']] == ['Buy milk']
    done = await call_iphone(authority, 'reminders.complete', {'reminder_id': 'r1'})
    assert done['data']['reminder']['completed'] is True
    assert [r['action'] for r in device.requests()] == ['reminders.add', 'reminders.list', 'reminders.complete']
    await device.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('label,kind', [('iPhone', 'ios'), ('Mac', 'mac')])
async def test_denied_reminders_access_reports_failure_naming_the_device(authorities, label, kind):
    authority = await authorities(f'home-{label}')
    device = await connect_phone(authority, label, kind=kind, responder=lambda payload: {
        'ok': False, 'error': {'code': 'permission_denied'}})
    await set_state(device, 'reminders', 'allowed')
    result = await call_iphone(authority, 'reminders.add', {'title': 'Buy milk'})
    assert result.get('success') is not True and result['code'] == 'permission_denied'
    assert f'off on {label}' in result['error'] and 'Settings' in result['error']
    await device.connection.close()


@pytest.mark.asyncio
async def test_when_phone_and_mac_are_online_the_device_the_user_is_on_gets_the_reminder(authorities):
    authority = await authorities('home-both')
    phone = await connect_phone(authority, 'iPhone', kind='ios', responder=eventkit_phone, attention='background')
    mac = await connect_phone(authority, 'Mac', kind='mac', responder=eventkit_phone, attention='foreground')
    await set_state(mac, 'reminders', 'allowed')
    await call_iphone(authority, 'reminders.add', {'title': 'Buy milk'})
    assert len(mac.requests()) == 1 and phone.requests() == []
    await phone.connection.close()
    await mac.connection.close()
