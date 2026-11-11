import asyncio
import json
import time

import pytest

from tests.gateway.device_tools_harness import (
    Approvals,
    call_device,
    call_devices_list,
    call_iphone,
    connect_phone,
    device_id_for,
    home_of,
    set_state,
)
from tests.waiting import async_wait_until

pytest_plugins = ('tests.gateway.device_tools_harness',)

MAC_MODEL = 'MacBookPro18,3'


def shell_answer(payload):
    assert payload['action'] == 'shell.run'
    return {'ok': True, 'result': {'exit_code': 0, 'stdout': 'Darwin\n', 'stderr': '', 'timed_out': False}}


def files_answer(payload):
    return {'ok': True, 'result': {'path': '/Users/sam/notes.txt', 'content': 'hello', 'size_bytes': 5}}


def reminder_answer(payload):
    return {'ok': True, 'result': {'reminder': {'id': 'r1', 'title': payload['args']['title']}}}


@pytest.fixture
def fast_timeouts(monkeypatch):
    from gateway import device_tools
    monkeypatch.setattr(device_tools, 'MIN_TIMEOUT_SECONDS', 0.2)
    monkeypatch.setattr(device_tools, 'DEFAULT_TIMEOUT_SECONDS', 0.3)
    monkeypatch.setattr(device_tools, 'DEFAULT_CONSENT_TIMEOUT_SECONDS', 0.3)
    monkeypatch.setattr(device_tools, 'THREAD_WAIT_MARGIN_SECONDS', 5.0)


async def mac(authority, label='Work Mac', *, responder=None, **kwargs):
    return await connect_phone(authority, label, kind='mac', model=MAC_MODEL, responder=responder, **kwargs)


async def mac_with(authority, label='Work Mac', responder=None, *connectors):
    phone = await mac(authority, label, responder=responder)
    for connector in connectors or ('shell', 'files'):
        await set_state(phone, connector, 'allowed')
    return phone


@pytest.mark.asyncio
async def test_a_bot_runs_a_command_on_the_named_mac_with_no_approval_prompt(authorities, monkeypatch):
    approvals = Approvals(monkeypatch, 'deny')
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    result = await call_device(authority, 'work mac', 'shell.run', {'command': 'uname', 'timeout_seconds': 10})
    request = work.requests()[0]
    assert request['action'] == 'shell.run' and request['connector'] == 'shell'
    assert request['args'] == {'command': 'uname', 'timeout_seconds': 10}
    assert request['needs_consent'] is False
    assert result['success'] is True and result['device'] == {'device_id': device_id_for('Work Mac'), 'name': 'Work Mac'}
    assert result['data'] == {'exit_code': 0, 'stdout': 'Darwin\n', 'stderr': '', 'timed_out': False,
                              'truncated': False}
    assert approvals.prompts == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_bot_reads_a_file_on_the_named_mac(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', files_answer)
    result = await call_device(authority, 'Work Mac', 'files.read', {'path': '~/notes.txt'})
    assert work.requests()[0]['action'] == 'files.read' and work.requests()[0]['args'] == {'path': '~/notes.txt'}
    assert result['success'] is True and result['data']['content'] == 'hello' and result['untrusted_content'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_bot_adds_a_reminder_on_the_named_iphone_not_the_mac(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', reminder_answer, 'reminders')
    pocket = await connect_phone(authority, 'Sam iPhone', responder=reminder_answer, model='iPhone15,2')
    await set_state(pocket, 'reminders', 'allowed')
    approvals = Approvals(monkeypatch, 'deny')
    result = await call_device(authority, 'Sam iPhone', 'reminders.add', {'title': 'Call mum'})
    assert result['success'] is True and result['data']['reminder']['title'] == 'Call mum'
    assert [r['action'] for r in pocket.requests()] == ['reminders.add'] and work.requests() == []
    assert approvals.prompts == []
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_apple_actions_work_on_a_named_mac_too(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', reminder_answer, 'reminders')
    result = await call_device(authority, 'Work Mac', 'reminders.add', {'title': 'Stand up'})
    assert result['success'] is True and work.requests()[0]['action'] == 'reminders.add'
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_connector_still_asking_keeps_both_approval_gates(authorities, monkeypatch):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=reminder_answer)
    approvals = Approvals(monkeypatch, 'deny')
    result = await call_device(authority, 'Sam iPhone', 'reminders.add', {'title': 'Call mum'})
    assert result['code'] == 'approval_denied' and len(approvals.prompts) == 1 and pocket.requests() == []
    approvals.choice = 'once'
    result = await call_device(authority, 'Sam iPhone', 'reminders.add', {'title': 'Call mum'})
    assert result['success'] is True and pocket.requests()[0]['needs_consent'] is True
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_devices_list_shows_every_device_with_type_state_last_seen_and_capabilities(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', None, 'shell')
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2')
    await set_state(pocket, 'reminders', 'allowed')
    await pocket.connection.close()
    listed = await call_devices_list(authority)
    rows = {row['name']: row for row in listed['devices']}
    assert set(rows) == {'Work Mac', 'Sam iPhone'}
    assert rows['Work Mac']['type'] == 'Mac' and rows['Work Mac']['status'] == 'online'
    assert rows['Work Mac']['capabilities']['shell'] == 'allowed' and 'files' not in rows['Work Mac']['capabilities']
    assert rows['Sam iPhone']['type'] == 'iPhone' and rows['Sam iPhone']['status'] == 'offline'
    assert rows['Sam iPhone']['capabilities']['reminders'] == 'allowed' and 'shell' not in rows['Sam iPhone']['capabilities']
    assert rows['Sam iPhone']['last_seen_at'].endswith('Z') and 'ago' in rows['Sam iPhone']['last_seen'] or \
        rows['Sam iPhone']['last_seen'].endswith('just now)')
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_device_of_another_profile_is_neither_listed_nor_reachable(authorities, tmp_path, monkeypatch):
    (tmp_path / 'install').mkdir()
    (tmp_path / 'install' / 'config.yaml').write_text('{}')
    mine = await authorities('install/profiles/mine')
    theirs = await authorities('install/profiles/theirs')
    from gateway import device_registry
    assert device_registry.install_root(mine.profile_id) == device_registry.install_root(theirs.profile_id)
    my_mac = await mac_with(mine, 'My Mac', shell_answer)
    their_mac = await mac_with(theirs, 'Neighbour Mac', shell_answer)
    names = {row['name'] for row in (await call_devices_list(mine))['devices']}
    assert names == {'My Mac'}
    for target in ('Neighbour Mac', device_id_for('Neighbour Mac')):
        result = await call_device(mine, target, 'shell.run', {'command': 'id'})
        assert result['code'] == 'device_not_found'
        assert [row['name'] for row in result['devices']] == ['My Mac']
        assert 'device-Neighbour-Mac' not in json.dumps(result['devices'])
    assert their_mac.requests() == [] and my_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_a_device_of_another_install_is_neither_listed_nor_reachable(authorities, monkeypatch):
    mine = await authorities('mine')
    theirs = await authorities('theirs')
    my_mac = await mac_with(mine, 'My Mac', shell_answer)
    their_mac = await mac_with(theirs, 'Neighbour Mac', shell_answer)
    assert {row['name'] for row in (await call_devices_list(mine))['devices']} == {'My Mac'}
    result = await call_device(mine, 'Neighbour Mac', 'shell.run', {'command': 'id'})
    assert result['code'] == 'device_not_found' and their_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_an_offline_device_is_listed_and_an_action_on_it_fails_at_once_and_is_never_queued(
        authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    await work.connection.close()
    started = time.monotonic()
    result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'uname'})
    assert result['code'] == 'phone_offline' and time.monotonic() - started < 2.0
    assert 'Work Mac is offline, last seen ' in result['error'] and 'Z' in result['error'] and 'just now' in result['error']
    assert result['last_seen_at'].endswith('Z')
    again = await mac(authority, 'Work Mac', responder=shell_answer)
    assert again.requests() == [] and work.requests() == []
    await again.connection.close()


@pytest.mark.asyncio
async def test_an_offline_apple_action_also_fails_at_once_because_pal_has_no_queue_for_it(authorities, monkeypatch):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=reminder_answer)
    await set_state(pocket, 'reminders', 'allowed')
    await pocket.connection.close()
    result = await call_device(authority, 'Sam iPhone', 'reminders.add', {'title': 'Call mum'})
    assert result['code'] == 'phone_offline' and 'Sam iPhone is offline, last seen' in result['error']
    from gateway import device_tools
    assert device_tools._pending == {}


@pytest.mark.asyncio
async def test_an_exact_label_matching_an_online_and_an_offline_device_is_ambiguous(authorities, monkeypatch):
    authority = await authorities()
    old = await mac_with(authority, 'Mac', shell_answer)
    old_id = device_id_for('Mac')
    await old.connection.close()
    from gateway import device_registry
    root = device_registry.install_root(authority.profile_id)
    device_registry.record_hello(root, device_id='other-mac-0001', kind='mac', label='Mac', model='', os_name='',
                                 app_version='1', now=time.time() - 3 * 3600)
    from gateway import device_connectors
    device_connectors.register_device(home_of(authority), 'other-mac-0001', 'Mac', kind='mac')
    fresh = await connect_phone(authority, 'Mac', kind='mac', model=MAC_MODEL, responder=shell_answer)
    fresh_id = device_id_for('Mac')
    assert fresh_id == old_id
    result = await call_device(authority, 'Mac', 'shell.run', {'command': 'uname'})
    assert result['code'] == 'ambiguous_device' and 'Ask the user which one' in result['error']
    states = {row['device_id']: row['status'] for row in result['devices']}
    assert states == {'other-mac-0001': 'offline', fresh_id: 'online'} or set(states.values()) == {'online', 'offline'}
    assert all(row['last_seen'] for row in result['devices']) and fresh.requests() == []
    by_id = await call_device(authority, fresh_id, 'shell.run', {'command': 'uname'})
    assert by_id['success'] is True
    await fresh.connection.close()


@pytest.mark.asyncio
async def test_two_devices_with_one_label_are_ambiguous_and_nothing_is_sent(authorities, monkeypatch):
    authority = await authorities()
    first = await mac_with(authority, 'Mac', shell_answer)
    from gateway import device_connectors, device_registry
    root = device_registry.install_root(authority.profile_id)
    device_registry.record_hello(root, device_id='second-mac-001', kind='mac', label='Mac', model='', os_name='',
                                 app_version='1', now=time.time())
    device_connectors.register_device(home_of(authority), 'second-mac-001', 'Mac', kind='mac')
    result = await call_device(authority, 'Mac', 'shell.run', {'command': 'uname'})
    assert result['code'] == 'ambiguous_device' and len(result['devices']) == 2 and first.requests() == []
    await first.connection.close()


@pytest.mark.asyncio
async def test_a_missing_device_fails_and_lists_the_available_names(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    result = await call_device(authority, 'Kitchen iPad', 'shell.run', {'command': 'uname'})
    assert result['code'] == 'device_not_found' and 'Work Mac' in result['error'] and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_action_with_no_device_never_goes_to_a_device(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    result = await call_device(authority, None, 'shell.run', {'command': 'uname'})
    assert result['code'] == 'invalid_args' and 'own tools' in result['error'] and work.requests() == []
    blank = await call_device(authority, '   ', 'shell.run', {'command': 'uname'})
    assert blank['code'] == 'invalid_args' and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_iphone_asked_to_run_a_shell_command_or_read_files_is_unsupported(authorities, monkeypatch):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=shell_answer, model='iPhone15,2')
    for action, args in (('shell.run', {'command': 'uname'}), ('files.read', {'path': '~/a.txt'}),
                         ('files.list', {'path': '~/'}), ('files.write', {'path': '~/a.txt', 'content': 'x'})):
        result = await call_device(authority, 'Sam iPhone', action, args)
        assert result['code'] == 'unsupported' and 'Sam iPhone' in result['error']
    assert pocket.requests() == []
    legacy = await call_iphone(authority, 'shell.run', {'command': 'uname'})
    assert legacy['code'] == 'invalid_args' and pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_shell_and_files_are_off_until_the_mac_itself_switches_them_on(authorities, monkeypatch):
    authority = await authorities()
    work = await mac(authority, 'Work Mac', responder=shell_answer)
    listed = (await call_devices_list(authority))['devices'][0]
    assert 'shell' not in listed['capabilities'] and 'files' not in listed['capabilities']
    for action, args in (('shell.run', {'command': 'uname'}), ('files.read', {'path': '~/a.txt'})):
        result = await call_device(authority, 'Work Mac', action, args)
        assert result['code'] == 'connector_off' and 'Work Mac' in result['error']
    assert work.requests() == []
    await set_state(work, 'shell', 'allowed')
    assert (await call_device(authority, 'Work Mac', 'shell.run', {'command': 'uname'}))['success'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_only_the_device_itself_can_switch_on_commands_and_files(authorities, monkeypatch):
    authority = await authorities()
    work = await mac(authority, 'Work Mac', responder=shell_answer)
    pocket = await connect_phone(authority, 'Sam iPhone')
    for connector in ('shell', 'files'):
        reply = await pocket.call('device_connectors.set', {
            'id': connector, 'state': 'allowed', 'device_id': device_id_for('Work Mac')})
        assert reply['error']['message'] == 'permission_denied' or 'permission_denied' in json.dumps(reply)
    result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'uname'})
    assert result['code'] == 'connector_off' and work.requests() == []
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_a_device_that_drops_mid_action_is_a_failure_with_an_unknown_effect(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac')
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'shell.run', {'command': 'rm -rf build'}))
    await async_wait_until(lambda: work.requests(), timeout=5)
    await work.connection.close()
    result = await call
    assert result['code'] == 'disconnected' and 'success' not in result
    assert 'Work Mac went offline during the action; the result is unknown, it may or may not have run' in result['error']
    assert 'effect of shell.run is unknown' in result['error']


@pytest.mark.asyncio
async def test_a_file_write_that_drops_mid_action_says_the_effect_is_unknown(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac')
    call = asyncio.create_task(call_device(authority, 'Work Mac', 'files.write', {'path': '~/a.txt', 'content': 'x'}))
    await async_wait_until(lambda: work.requests(), timeout=5)
    await work.connection.close()
    result = await call
    assert result['code'] == 'disconnected' and 'effect of files.write is unknown' in result['error']


@pytest.mark.asyncio
async def test_a_command_that_never_answers_times_out_and_the_device_is_told_to_stop(
        authorities, monkeypatch, fast_timeouts):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac')
    result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'sleep 99', 'timeout_seconds': 1})
    assert result['code'] == 'timeout' and 'Work Mac' in result['error'] and 'effect is unknown' in result['error']
    request = work.requests()[0]
    assert request['deadline_seconds'] >= 6
    await async_wait_until(lambda: work.events('device.tool.cancel'), timeout=10)
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_command_the_device_stopped_at_its_own_limit_is_not_reported_as_success(authorities, monkeypatch):
    def answer(payload):
        return {'ok': True, 'result': {'exit_code': None, 'stdout': 'partial', 'stderr': '', 'timed_out': True}}
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', answer)
    result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'sleep 99', 'timeout_seconds': 1})
    assert result['code'] == 'timeout' and 'success' not in result and result['data']['stdout'] == 'partial'
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_result_over_the_cap_is_truncated_with_a_marker_never_dropped(authorities, monkeypatch):
    from gateway import device_tools

    def answer(payload):
        return {'ok': True, 'result': {'exit_code': 0, 'stdout': 'a\n' * 400_000, 'stderr': 'e' * 90_000,
                                       'timed_out': False}}
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', answer)
    result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'yes'})
    data = result['data']
    assert result['success'] is True and data['truncated'] is True
    assert data['stdout'].startswith('a\n') and 'truncated' in data['stdout'] and data['stdout']
    assert len(json.dumps(data, ensure_ascii=False)) <= device_tools.MAX_RESULT_BYTES
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_file_over_the_cap_is_truncated_with_a_marker(authorities, monkeypatch):
    def answer(payload):
        return {'ok': True, 'result': {'path': '/Users/sam/big.log', 'content': 'x' * 500_000, 'size_bytes': 500_000}}
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', answer)
    result = await call_device(authority, 'Work Mac', 'files.read', {'path': '~/big.log'})
    assert result['success'] is True and result['data']['truncated'] is True
    assert 'truncated' in result['data']['content'] and result['data']['size_bytes'] == 500_000
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_permission_refusal_on_the_device_names_the_device(authorities, monkeypatch):
    def refuse(payload):
        return {'ok': False, 'error': {'code': 'permission_denied', 'message': 'Operation not permitted: ~/Documents'}}
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', refuse)
    result = await call_device(authority, 'Work Mac', 'files.read', {'path': '~/Documents/a.txt'})
    assert result['code'] == 'permission_denied' and 'Work Mac' in result['error'] and 'success' not in result
    await work.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', [
    ('shell.run', {'command': ''}),
    ('shell.run', {'command': 'ls', 'timeout_seconds': 0}),
    ('shell.run', {'command': 'ls', 'timeout_seconds': 301}),
    ('shell.run', {'command': 'ls', 'cwd': 'relative/dir'}),
    ('shell.run', {'command': 'ls', 'extra': 1}),
    ('files.read', {'path': 'relative.txt'}),
    ('files.read', {}),
    ('files.list', {'path': '~/', 'limit': 0}),
    ('files.write', {'path': '/tmp/x', 'content': 'x' * 200_001}),
])
async def test_invalid_arguments_never_reach_the_device(authorities, monkeypatch, action, args):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    result = await call_device(authority, 'Work Mac', action, args)
    assert result['code'] == 'invalid_args' and work.requests() == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_failed_device_action_is_never_reported_as_success(authorities, monkeypatch):
    def failed(payload):
        return {'ok': False, 'error': {'code': 'failed', 'message': 'disk full'}}
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', failed)
    result = await call_device(authority, 'Work Mac', 'files.write', {'path': '~/a.txt', 'content': 'x'})
    assert result['code'] == 'device_failed' and 'success' not in result and 'Work Mac' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_legacy_iphone_tool_still_reaches_a_mac_for_apple_actions_but_never_for_shell(authorities, monkeypatch):
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', lambda payload: {'ok': True, 'result': {'reminders': []}}, 'reminders', 'shell')
    await set_state(work, 'reminders', 'allowed')
    result = await call_iphone(authority, 'reminders.list', {})
    assert result['success'] is True and [r['action'] for r in work.requests()] == ['reminders.list']
    refused = await call_iphone(authority, 'shell.run', {'command': 'id'})
    assert refused['code'] == 'invalid_args' and len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_the_device_tools_are_in_the_toolset_and_their_text_tells_the_bot_how_to_choose(authorities):
    from model_tools import get_tool_definitions
    from toolsets import resolve_toolset
    assert {'iphone', 'devices_list', 'device'} <= set(resolve_toolset('iphone'))
    authority = await authorities()
    work = await mac_with(authority, 'Work Mac', shell_answer)
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    token = set_hermes_home_override(home_of(authority))
    try:
        defs = {d['function']['name']: d['function'] for d in get_tool_definitions(enabled_toolsets=['iphone'], quiet_mode=True)}
    finally:
        reset_hermes_home_override(token)
    text = defs['device']['description']
    assert 'only when the user\'s message names a device' in text and 'ask which one' in text
    assert 'shell.run' in text and 'files.read' in text and 'nothing is queued' in text
    assert 'shell.run' not in defs['iphone']['description']
    await work.connection.close()
