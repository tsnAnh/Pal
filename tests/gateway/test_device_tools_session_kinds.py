import json
from dataclasses import replace

import pytest

from tests.gateway.device_tools_harness import call_device, connect_phone, set_state
from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner

pytest_plugins = ('tests.gateway.device_tools_harness',)

DEVICE_TOOLS = {'iphone', 'devices_list', 'device'}

FAMILIES = {
    'calendar': ('calendar.list_events', {'start': '2030-01-01T00:00:00Z', 'end': '2030-01-02T00:00:00Z'}, {'events': []}),
    'reminders': ('reminders.list', {}, {'reminders': []}),
    'contacts': ('contacts.search', {'query': 'Sam'}, {'contacts': []}),
    'location': ('location.current', {}, {'latitude': 1.5, 'longitude': 2.5}),
    'alarms': ('alarms.list', {}, {'alarms': []}),
    'home': ('home.list_accessories', {}, {'accessories': []}),
    'shell': ('shell.run', {'command': 'uname -srm'}, {'exit_code': 0, 'stdout': 'Darwin 25.0 arm64\n'}),
    'files': ('files.list', {'path': '~/'}, {'path': '/Users/sam', 'entries': []}),
    'input': ('input.key', {'key': 'return'}, {'events': 2}),
    'screen': ('screen.read', {}, {'text': 'Inbox', 'display': 1}),
    'notifications': ('notify.post', {'title': 'Hi', 'body': 'There'}, {'identifier': 'n1'}),
    'clipboard': ('clipboard.read', {}, {'types': ['text'], 'text': 'copied'}),
    'apps': ('apps.list', {}, {'apps': []}),
}


def offered(authority, policy, session_id):
    import model_tools
    from gateway.session_policy import policy_turn_toolsets
    from toolsets import session_disabled_toolsets
    enabled = policy_turn_toolsets(authority, policy, {}, session_id)
    disabled = session_disabled_toolsets(None, policy.platform, enabled=enabled)
    tools = model_tools.get_tool_definitions(enabled_toolsets=enabled, disabled_toolsets=disabled, quiet_mode=True)
    return {tool['function']['name'] for tool in tools or []} & DEVICE_TOOLS


def switch_mac(home, registered):
    from gateway import device_connectors as connectors
    from gateway.device_connectors import Connector
    if not registered:
        return
    connectors.register_device(home, 'mac-device-0001', 'Work Mac', kind='mac')
    path = home / connectors.FILE_NAME
    stored = json.loads(path.read_text())
    stored['devices']['mac-device-0001']['connectors'] = {c.value: {'state': 'off'} for c in Connector}
    path.write_text(json.dumps(stored))


KINDS = {
    'cli': dict(source='cli'),
    'bot_chat': dict(source='cli', title='Bot Chat', follow_profile_config=True),
    'ios': dict(source='ios'),
}
NOT_ENABLED = {
    'tui': dict(source='tui'),
    'gui': dict(source='gui'),
    'oneshot': dict(source='oneshot'),
    'tool': dict(source='tool'),
    'cli_with_picked_toolsets': dict(source='cli', toolsets=['web']),
}


async def sessions(tmp_path, monkeypatch, kinds, registered):
    monkeypatch.chdir(tmp_path)
    store, _runner, authority, owner = _owner(tmp_path / 'home', monkeypatch, {'model': {'default': 'm'}})
    profile_home = tmp_path / authority.profile_id
    profile_home.mkdir()
    for home in (tmp_path / 'home', profile_home):
        switch_mac(home, registered)
    made = {}
    for name, extra in kinds.items():
        live, policy = await _create(owner, authority, name, tmp_path, **extra)
        made[name] = (policy, live.source.chat_id)
    return store, authority, owner, made


@pytest.mark.asyncio
@pytest.mark.parametrize('registered', [True, False])
async def test_cli_bot_chat_and_ios_sessions_are_offered_the_device_tools_exactly_when_a_device_is_registered(
        tmp_path, monkeypatch, registered):
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, KINDS, registered)
    try:
        for name, (policy, session_id) in made.items():
            assert offered(authority, policy, session_id) == (DEVICE_TOOLS if registered else set()), name
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_unattended_and_picked_toolset_sessions_never_get_the_device_tools(tmp_path, monkeypatch):
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, NOT_ENABLED, True)
    try:
        for name, (policy, session_id) in made.items():
            assert not offered(authority, policy, session_id), name
        policy, session_id = made['tui']
        for source in ('cron', 'kanban', 'a2a'):
            stored = replace(policy, source=source, platform=source, request_json=json.dumps({'source': source}))
            assert not offered(authority, stored, session_id), source
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_a_cli_chat_with_iphone_disabled_in_the_profile_config_is_not_offered_the_tools(tmp_path, monkeypatch):
    from gateway.session_policy import policy_turn_toolsets
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, {'cli': KINDS['cli']}, True)
    try:
        policy, session_id = made['cli']
        config = {'agent': {'disabled_toolsets': ['iphone']}}
        assert 'iphone' not in policy_turn_toolsets(authority, policy, config, session_id)
    finally:
        await owner.close()
        store.close_all_db_handles()


def test_every_connector_of_the_catalog_has_a_family_under_test():
    from gateway.device_actions import CONNECTOR_CATALOG
    assert {info.connector.value for info in CONNECTOR_CATALOG} == set(FAMILIES)


@pytest.mark.asyncio
@pytest.mark.parametrize('family', sorted(FAMILIES))
async def test_a_stored_off_for_any_family_never_hides_the_tools_from_cli_and_bot_chat_sessions(tmp_path, monkeypatch, family):
    store, authority, owner, made = await sessions(tmp_path, monkeypatch, {k: KINDS[k] for k in ('cli', 'bot_chat')}, True)
    try:
        for name, (policy, session_id) in made.items():
            assert offered(authority, policy, session_id) == DEVICE_TOOLS, name
    finally:
        await owner.close()
        store.close_all_db_handles()


@pytest.mark.asyncio
@pytest.mark.parametrize('family', sorted(FAMILIES))
async def test_every_family_reaches_the_owners_mac_with_no_switch_and_ignores_an_off_set_call(authorities, family):
    action, args, answer = FAMILIES[family]
    authority = await authorities()
    mac = await connect_phone(authority, 'Work Mac', kind='mac', model='MacBookPro18,3',
                              responder=lambda payload: {'ok': True, 'result': answer})
    if family != 'input':
        await set_state(mac, family, 'off')
    result = await call_device(authority, 'Work Mac', action, args)
    assert result['success'] is True and result['untrusted_content'] is True
    assert [(r['action'], r['connector']) for r in mac.requests()] == [(action, family)]
    await mac.connection.close()


@pytest.mark.asyncio
async def test_stop_refuses_mouse_and_keyboard_until_the_app_resumes_it(authorities):
    action, args, answer = FAMILIES['input']
    authority = await authorities()
    mac = await connect_phone(authority, 'Work Mac', kind='mac', model='MacBookPro18,3',
                              responder=lambda payload: {'ok': True, 'result': answer})
    await set_state(mac, 'input', 'off')
    stopped = await call_device(authority, 'Work Mac', action, args)
    assert stopped['code'] == 'connector_off' and mac.requests() == []
    await set_state(mac, 'input', 'allowed')
    assert (await call_device(authority, 'Work Mac', action, args))['success'] is True
    await mac.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('family', sorted(FAMILIES))
async def test_a_family_never_reaches_a_device_of_another_profile(authorities, family):
    action, args, answer = FAMILIES[family]
    mine, theirs = await authorities('mine'), await authorities('theirs')
    neighbour = await connect_phone(theirs, 'Neighbour Mac', kind='mac', model='MacBookPro18,3',
                                    responder=lambda payload: {'ok': True, 'result': answer})
    await set_state(neighbour, family, 'allowed')
    result = await call_device(mine, 'Neighbour Mac', action, args)
    assert result['code'] == 'device_not_found' and neighbour.requests() == []
    await neighbour.connection.close()
