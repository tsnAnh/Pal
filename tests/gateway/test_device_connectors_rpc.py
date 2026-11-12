import pytest

from tests.gateway.device_tools_harness import (
    FakePhone,
    connect_phone,
    device_id_for,
    home_of,
)

pytest_plugins = ('tests.gateway.device_tools_harness',)


async def _bare_phone(authority) -> FakePhone:
    import asyncio
    from gateway.session_controls import AuthorityConnection
    phone = FakePhone(asyncio.get_running_loop())
    phone.connection = AuthorityConnection(authority, phone, {'user_id': 'owner'})
    return phone


def _error(reply: dict) -> str:
    return reply['error']['message']


@pytest.mark.asyncio
async def test_listing_before_the_device_is_declared_asks_for_hello_first(authorities):
    phone = await _bare_phone(await authorities())
    reply = await phone.call('device_connectors.list', {})
    assert _error(reply) == 'invalid_params'
    await phone.connection.close()


@pytest.mark.asyncio
async def test_a_new_device_lists_all_six_connectors_asking_with_the_product_copy(authorities):
    phone = await connect_phone(await authorities())
    result = (await phone.call('device_connectors.list', {}))['result']
    assert result['device_id'] == device_id_for('iPhone')
    assert [(c['id'], c['title'], c['subtitle'], c['state'], c['os_permission']) for c in result['connectors']] == [
        ('calendar', 'Calendar', 'See your day and add events', 'ask', 'not_determined'),
        ('home', 'Home', 'Control lights, locks and more', 'ask', 'not_determined'),
        ('reminders', 'Reminders', 'Set and check reminders', 'ask', 'not_determined'),
        ('contacts', 'Contacts', 'Look up people you know', 'ask', 'not_determined'),
        ('location', 'Location', 'Find places near you', 'ask', 'not_determined'),
        ('alarms', 'Alarms', 'Set alarms and timers', 'ask', 'not_determined'),
    ]
    await phone.connection.close()


@pytest.mark.asyncio
async def test_state_and_os_permission_persist_per_connector_across_a_new_connection(authorities):
    authority = await authorities()
    phone = await connect_phone(authority)
    for params in ({'id': 'calendar', 'state': 'allowed'}, {'id': 'home', 'state': 'off'},
                   {'id': 'location', 'os_permission': 'granted', 'state': 'allowed'},
                   {'id': 'alarms', 'os_permission': 'unsupported'}):
        assert 'result' in await phone.call('device_connectors.set', params)
    await phone.connection.close()
    again = await connect_phone(authority)
    listed = (await again.call('device_connectors.list', {}))['result']['connectors']
    assert {c['id']: (c['state'], c['os_permission']) for c in listed} == {
        'calendar': ('allowed', 'not_determined'), 'home': ('ask', 'not_determined'),
        'reminders': ('ask', 'not_determined'), 'contacts': ('ask', 'not_determined'),
        'location': ('allowed', 'granted'), 'alarms': ('ask', 'unsupported')}
    await again.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('params', [
    {'id': 'calendar'},
    {'id': 'telepathy', 'state': 'allowed'},
    {'id': 'calendar', 'state': 'sometimes'},
    {'id': 'calendar', 'os_permission': 'maybe'},
    {'id': 'calendar', 'state': 'allowed', 'device_id': 'short'},
])
async def test_malformed_connector_changes_are_refused_and_change_nothing(authorities, params):
    phone = await connect_phone(await authorities())
    before = (await phone.call('device_connectors.list', {}))['result']
    assert 'error' in await phone.call('device_connectors.set', params)
    assert (await phone.call('device_connectors.list', {}))['result'] == before
    await phone.connection.close()


@pytest.mark.asyncio
async def test_a_device_reports_only_its_own_os_permission_and_unknown_devices_are_not_found(authorities):
    authority = await authorities()
    first = await connect_phone(authority)
    other = await connect_phone(authority, 'Other')
    foreign = await first.call('device_connectors.set', {
        'id': 'contacts', 'os_permission': 'granted', 'device_id': device_id_for('Other')})
    assert _error(foreign) == 'permission_denied'
    managed = await first.call('device_connectors.set', {
        'id': 'contacts', 'state': 'off', 'device_id': device_id_for('Other')})
    assert {c['id']: c['state'] for c in managed['result']['connectors']}['contacts'] == 'ask'
    missing = await first.call('device_connectors.list', {'device_id': 'nobody-12345'})
    assert _error(missing) == 'not_found'
    await first.connection.close()
    await other.connection.close()


@pytest.mark.asyncio
async def test_an_unknown_parameter_is_refused_by_the_declared_contract(authorities):
    phone = await connect_phone(await authorities())
    reply = await phone.call('device_connectors.set', {'id': 'calendar', 'state': 'off', 'bogus': 1})
    assert reply['error']['code'] == 4001 and 'bogus' in reply['error']['data']['fields']
    await phone.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('params', [
    {'request_id': 'req-12345678', 'ok': True},
    {'request_id': 'req-12345678', 'ok': False},
    {'request_id': 'req-12345678', 'ok': True, 'result': {}, 'error': {'code': 'failed'}},
    {'request_id': 'req-12345678', 'ok': False, 'error': {'code': 'exploded'}},
    {'request_id': 'x', 'ok': True, 'result': {}},
])
async def test_a_malformed_answer_is_refused_before_it_can_settle_anything(authorities, params):
    phone = await connect_phone(await authorities())
    assert 'error' in await phone.call('device.tool.respond', params)
    await phone.connection.close()


@pytest.mark.asyncio
async def test_answering_a_request_nobody_asked_is_recorded_as_false(authorities):
    phone = await connect_phone(await authorities())
    reply = await phone.respond('req-12345678', {'ok': True, 'result': {'contacts': []}})
    assert reply['result'] == {'recorded': False}
    await phone.connection.close()


@pytest.mark.asyncio
async def test_only_an_ios_declaration_with_device_tools_registers_a_device(authorities):
    from gateway import device_connectors
    from tests.gateway.device_tools_harness import HELLO
    authority = await authorities()
    desktop = await _bare_phone(authority)
    reply = await desktop.call('client.hello', {**HELLO, 'kind': 'desktop', 'device_id': 'desktop-12345'})
    assert reply['result']['recorded'] is True
    assert device_connectors.known_device_ids(home_of(authority)) == []
    assert 'error' in await desktop.call('device_connectors.list', {})
    await desktop.connection.close()
