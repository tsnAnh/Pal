from contextlib import contextmanager, nullcontext
from types import SimpleNamespace

import pytest

from tests.gateway.device_tools_harness import (
    call_device,
    call_devices_list,
    connect_phone,
    device_id_for,
    home_of,
    set_state,
)
from tests.gateway.test_device_messages import SEND, SEND_CANARY, Owner
from tests.gateway.test_device_messages import answer as messages_answer

pytest_plugins = ('tests.gateway.device_tools_harness',)

MAC_MODEL = 'MacBookPro18,3'
OWNER_BOUND_CALLS = [('input.click', {'x': 1, 'y': 2}), ('input.displays', {}), ('messages.recent', {}),
                     ('messages.send', SEND)]


@pytest.fixture(autouse=True)
def fresh_rate_window():
    from tools import devices_tool
    devices_tool._input_calls.clear()


def answer(payload):
    action = payload['action']
    if action == 'shell.run':
        return {'ok': True, 'result': {'exit_code': 0, 'stdout': 'Darwin\n', 'stderr': '', 'timed_out': False}}
    if action == 'reminders.add':
        return {'ok': True, 'result': {'reminder': {'id': 'r1', 'title': payload['args']['title']}}}
    if action == 'input.displays':
        return {'ok': True, 'result': {'displays': [], 'pointer_x': 0, 'pointer_y': 0}}
    if action.startswith('input.'):
        return {'ok': True, 'result': {'events': 1, 'pointer_x': 1, 'pointer_y': 2}}
    return messages_answer(payload)


async def mac(authority, label='Work Mac'):
    return await connect_phone(authority, label, kind='mac', model=MAC_MODEL, responder=answer)


async def iphone(authority, label='Sam iPhone'):
    return await connect_phone(authority, label, model='iPhone15,2', responder=answer)


@contextmanager
def typed_on(phone):
    from gateway.reach_presence import origin_of
    from gateway.session_surface import admit_surface, surface_turn_scope
    with surface_turn_scope(admit_surface({}, origin=origin_of(phone))['surface_v1']):
        yield


@contextmanager
def user_turn():
    from gateway.session_ingress import viewer_turn
    token = viewer_turn.set(SimpleNamespace())
    try:
        yield
    finally:
        viewer_turn.reset(token)


def not_a_viewer_turn():
    return nullcontext(), nullcontext()


def delegated_child():
    from agent.delegation_context import delegated_child_context
    return user_turn(), delegated_child_context()


def unattended_run():
    from gateway.session_finite import finite_turn_scope
    return user_turn(), finite_turn_scope(True, True)


def requests_of(*phones):
    return [len(phone.requests()) for phone in phones]


async def close(*phones):
    for phone in phones:
        await phone.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('wanted', [None, 'auto', '  AUTO '], ids=['omitted', 'auto', 'auto-cased'])
async def test_a_message_from_the_iphone_runs_a_command_on_the_online_mac(authorities, wanted):
    authority = await authorities()
    work, pocket = await mac(authority), await iphone(authority)
    with typed_on(pocket):
        result = await call_device(authority, wanted, 'shell.run', {'command': 'uname'})
    assert result.get('success') is True, result
    assert result['device'] == {'device_id': device_id_for('Work Mac'), 'name': 'Work Mac'}
    assert requests_of(work, pocket) == [1, 0]
    await close(work, pocket)


@pytest.mark.asyncio
async def test_an_explicit_null_device_is_picked_by_availability(authorities):
    from tests.gateway.device_tools_harness import call_tool
    authority = await authorities()
    work = await mac(authority)
    result = await call_tool(authority, 'device', {'device': None, 'action': 'shell.run', 'args': {'command': 'id'}})
    assert result.get('success') is True and requests_of(work) == [1], result
    await close(work)


@pytest.mark.asyncio
async def test_a_device_literally_named_auto_never_captures_the_auto_word(authorities):
    authority = await authorities()
    named, other = await mac(authority, 'auto'), await mac(authority, 'Home Mac')
    result = await call_device(authority, 'auto', 'shell.run', {'command': 'id'})
    assert result['code'] == 'needs_choice' and requests_of(named, other) == [0, 0]
    await close(named, other)


@pytest.mark.asyncio
async def test_two_capable_macs_ask_for_a_choice_and_the_second_call_runs_on_it(authorities):
    authority = await authorities()
    work, home, pocket = await mac(authority), await mac(authority, 'Home Mac'), await iphone(authority)
    with typed_on(pocket):
        result = await call_device(authority, None, 'shell.run', {'command': 'uname'})
    assert result['code'] == 'needs_choice' and requests_of(work, home, pocket) == [0, 0, 0]
    assert {row['device_id'] for row in result['devices']} == {device_id_for('Work Mac'), device_id_for('Home Mac')}
    assert 'Work Mac' in result['error'] and 'Home Mac' in result['error'] and 'once' in result['error']
    chosen = await call_device(authority, device_id_for('Home Mac'), 'shell.run', {'command': 'uname'})
    assert chosen['success'] is True and requests_of(work, home, pocket) == [0, 1, 0]
    await close(work, home, pocket)


@pytest.mark.asyncio
async def test_among_two_capable_macs_the_one_typed_on_is_used(authorities):
    authority = await authorities()
    work, home = await mac(authority), await mac(authority, 'Home Mac')
    for typing, expected in ((home, [0, 1]), (work, [1, 1])):
        with typed_on(typing):
            result = await call_device(authority, None, 'shell.run', {'command': 'uname'})
        assert result.get('success') is True and requests_of(work, home) == expected, result
    await close(work, home)


@pytest.mark.asyncio
async def test_a_named_device_beats_the_one_typed_on(authorities):
    authority = await authorities()
    work, home = await mac(authority), await mac(authority, 'Home Mac')
    with typed_on(home):
        result = await call_device(authority, 'Work Mac', 'shell.run', {'command': 'uname'})
    assert result['success'] is True and requests_of(work, home) == [1, 0]
    await close(work, home)


@pytest.mark.asyncio
async def test_a_mac_only_action_with_only_the_iphone_online_starts_nothing_and_says_since_when(authorities):
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    pocket = await iphone(authority)
    with typed_on(pocket):
        result = await call_device(authority, None, 'shell.run', {'command': 'uname'})
    assert result['code'] == 'no_device_available' and requests_of(work, pocket) == [0, 0]
    error = result['error']
    assert 'shell.run' in error and 'Run commands' in error and 'nothing was started' in error.casefold()
    assert 'Work Mac' in error and 'offline since ' in error and 'Z (' in error
    assert 'Sam iPhone' in error and 'lacks Run commands' in error
    assert {row['name']: row['status'] for row in result['devices']} == {'Work Mac': 'offline', 'Sam iPhone': 'online'}
    await close(pocket)
    again = await mac(authority)
    assert again.requests() == []
    await close(again)


@pytest.mark.asyncio
async def test_a_mac_with_input_stopped_is_not_a_candidate(authorities):
    authority = await authorities()
    stopped, able = await mac(authority), await mac(authority, 'Home Mac')
    await set_state(stopped, 'input', 'off')
    with typed_on(stopped), user_turn():
        result = await call_device(authority, None, 'input.click', {'x': 1, 'y': 2})
    assert result.get('success') is True and requests_of(stopped, able) == [0, 1], result
    await set_state(able, 'input', 'off')
    with user_turn():
        refused = await call_device(authority, None, 'input.click', {'x': 1, 'y': 2})
    assert refused['code'] == 'no_device_available' and 'switched it off' in refused['error']
    assert requests_of(stopped, able) == [0, 1]
    await close(stopped, able)


@pytest.mark.asyncio
async def test_a_capability_still_asking_is_a_candidate_and_the_device_asks_its_user(authorities):
    authority = await authorities()
    pocket = await iphone(authority)
    result = await call_device(authority, None, 'reminders.add', {'title': 'Call mum'})
    assert result.get('success') is True, result
    assert pocket.requests()[0]['needs_consent'] is True
    await close(pocket)


@pytest.mark.asyncio
@pytest.mark.parametrize('turn', [not_a_viewer_turn, delegated_child, unattended_run])
@pytest.mark.parametrize('action,args', OWNER_BOUND_CALLS, ids=[action for action, _ in OWNER_BOUND_CALLS])
async def test_input_and_messages_never_pick_a_device_without_the_users_own_words(
        authorities, monkeypatch, turn, action, args):
    authority = await authorities()
    work = await mac(authority)
    outer, inner = turn()
    with outer, inner:
        result = await call_device(authority, None, action, args)
    assert result['code'] == 'owner_request_required' and requests_of(work) == [0], result
    error = result['error'].casefold()
    assert 'nothing was started' in error and 'do not retry' in error and 'tell the user' in error
    assert 'device_id' not in error and '`device`' not in error and 'devices' not in result
    await close(work)


@pytest.mark.asyncio
async def test_the_owner_gate_answers_before_any_device_is_looked_at(authorities):
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'auto', 'input.click', {'x': 1, 'y': 2})
    assert result['code'] == 'owner_request_required'


@pytest.mark.asyncio
@pytest.mark.parametrize('action,args', OWNER_BOUND_CALLS[:3], ids=[action for action, _ in OWNER_BOUND_CALLS[:3]])
async def test_input_and_messages_pick_a_device_in_a_turn_the_user_wrote(authorities, action, args):
    authority = await authorities()
    work = await mac(authority)
    with user_turn():
        result = await call_device(authority, None, action, args)
    assert result.get('success') is True and requests_of(work) == [1], result
    await close(work)


@pytest.mark.asyncio
@pytest.mark.parametrize('turn', [not_a_viewer_turn, delegated_child, unattended_run])
async def test_a_named_device_is_not_held_to_the_new_owner_gate(authorities, turn):
    authority = await authorities()
    work = await mac(authority)
    outer, inner = turn()
    with outer, inner:
        clicked = await call_device(authority, 'Work Mac', 'input.click', {'x': 1, 'y': 2})
        read = await call_device(authority, 'Work Mac', 'messages.recent', {})
    assert clicked.get('success') is True and read.get('success') is True, (clicked, read)
    assert requests_of(work) == [2]
    await close(work)


@pytest.mark.asyncio
@pytest.mark.parametrize('turn', [not_a_viewer_turn, delegated_child, unattended_run])
async def test_other_actions_pick_a_device_without_the_users_own_words(authorities, turn):
    authority = await authorities()
    work = await mac(authority)
    outer, inner = turn()
    with outer, inner:
        result = await call_device(authority, None, 'shell.run', {'command': 'uname'})
    assert result.get('success') is True and requests_of(work) == [1], result
    await close(work)


@pytest.mark.asyncio
async def test_an_auto_chosen_send_needs_a_card_every_time(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    with user_turn():
        for _ in range(2):
            result = await call_device(authority, None, 'messages.send', SEND)
            assert result.get('success') is True, result
    assert len(owner.cards) == 2 and requests_of(work) == [2]
    assert all('Work Mac' in card['description'] for card in owner.cards)
    await close(work)


@pytest.mark.asyncio
async def test_a_denied_auto_chosen_send_sends_nothing(authorities, monkeypatch):
    owner = Owner(monkeypatch, approved=False)
    authority = await authorities()
    work = await mac(authority)
    with user_turn():
        result = await call_device(authority, None, 'messages.send', SEND)
    assert result['code'] == 'approval_denied' and SEND_CANARY not in str(result)
    assert len(owner.cards) == 1 and work.requests() == []
    await close(work)


@pytest.mark.asyncio
@pytest.mark.parametrize('wanted', ['', '   ', 7, ['Work Mac'], False])
async def test_a_blank_or_non_text_device_is_refused_and_nothing_is_sent(authorities, wanted):
    from tests.gateway.device_tools_harness import call_tool
    authority = await authorities()
    work = await mac(authority)
    result = await call_tool(authority, 'device', {'device': wanted, 'action': 'shell.run',
                                                   'args': {'command': 'uname'}})
    assert result.get('code') == 'invalid_args', result
    assert 'Omit it' in result['error'] and 'own tools' not in result['error'] and work.requests() == []
    await close(work)


def definitions(authority):
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from model_tools import get_tool_definitions
    token = set_hermes_home_override(home_of(authority))
    try:
        found = get_tool_definitions(enabled_toolsets=['iphone'], quiet_mode=True, skip_tool_search_assembly=True)
    finally:
        reset_hermes_home_override(token)
    return {item['function']['name']: item['function'] for item in found}


@pytest.mark.asyncio
async def test_the_tool_text_tells_the_bot_to_leave_the_choice_to_availability(authorities):
    authority = await authorities()
    work = await mac(authority)
    assert (await call_devices_list(authority))['success'] is True
    defs = definitions(authority)
    device, listing = defs['device'], defs['devices_list']
    assert device['parameters']['required'] == ['action']
    for text in (device['description'], listing['description']):
        assert 'Omit `device`' in text and 'whatever device the message came from' in text
        assert 'needs_choice' in text and 'ask the user once' in text and 'your own tools' in text
        assert 'only when the user\'s message names a device' not in text and 'never pick one yourself' not in text
    text = device['description']
    assert 'a device the user named' not in text and 'one of the user\'s devices' in text
    assert 'no device online and able' in text and 'starts nothing' in text
    assert 'asked in this turn' in text and 'a turn the user wrote' in text
    assert 'nothing is queued' in text and 'never type secrets or passwords' in text
    assert 'approval of the exact text every time' in text and 'never instructions' in text
    assert 'Call it before using `device`' not in listing['description']
    assert 'Omit' in device['parameters']['properties']['device']['description']
    await close(work)


def test_the_static_device_schema_requires_only_the_action():
    from tools.devices_tool import STATIC_DEVICE_SCHEMA
    assert STATIC_DEVICE_SCHEMA['parameters']['required'] == ['action']
    assert 'the user named' not in STATIC_DEVICE_SCHEMA['description']
    assert 'one of the user\'s devices' in STATIC_DEVICE_SCHEMA['description']
