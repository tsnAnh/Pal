import pytest

from gateway.device_actions import ACTIONS
from gateway.device_directory import DeviceView, last_seen_text
from tui_gateway.contracts.canonical_device import DeviceConnectorState as State

NOW = 1_800_000_000.0
SHELL = ACTIONS['shell.run']
REMIND = ACTIONS['reminders.add']
CLICK = ACTIONS['input.click']


def device(label, kind='mac', *, online=True, seen=NOW, connectors=None, device_id=None):
    if connectors is None:
        connectors = {'reminders': State.ALLOWED}
        if kind == 'mac':
            connectors.update({'shell': State.ALLOWED, 'input': State.ALLOWED})
    type_ = {'mac': 'Mac', 'ios': 'iPhone'}[kind]
    return DeviceView(device_id=device_id or f'id-{kind}-{label}', label=label, kind=kind, type=type_, model='', os='',
                      online=online, last_seen_at=NOW if online else seen, connectors=connectors)


def routed(views, spec=SHELL, typing=None):
    from gateway.devices.routing import route
    return route(views, spec, typing, NOW)


def typed(kind, label):
    from gateway.devices.routing import TypingDevice
    return TypingDevice(kind=kind, label=label)


def test_the_one_online_capable_device_is_chosen_over_an_offline_one():
    asleep, awake = device('Old Mac', online=False, seen=NOW - 60), device('Work Mac')
    found = routed([asleep, awake], typing=typed('mac', 'Old Mac'))
    assert found.device is awake and found.code == ''


def test_a_device_whose_capability_is_off_is_never_chosen():
    stopped = device('Stopped Mac', connectors={'input': State.OFF})
    absent = device('Bare Mac', connectors={})
    able = device('Work Mac')
    assert routed([stopped, absent, able], CLICK, typed('mac', 'Stopped Mac')).device is able
    refused = routed([stopped, absent], CLICK)
    assert refused.device is None and refused.code == 'no_device_available'


def test_an_iphone_is_never_chosen_for_a_mac_only_action_even_if_it_claims_the_capability():
    pocket = device('Sam iPhone', 'ios', connectors={'shell': State.ALLOWED})
    refused = routed([pocket], SHELL, typed('ios', 'Sam iPhone'))
    assert refused.device is None and refused.code == 'no_device_available'
    work = device('Work Mac')
    assert routed([pocket, work], SHELL, typed('ios', 'Sam iPhone')).device is work


def test_a_capability_still_asking_its_user_stays_a_candidate():
    pocket = device('Sam iPhone', 'ios', connectors={'reminders': State.ASK})
    assert routed([pocket], REMIND).device is pocket
    work = device('Work Mac')
    both = routed([pocket, work], REMIND)
    assert both.code == 'needs_choice' and both.candidates == (pocket, work)


def test_several_ready_devices_ask_the_user_once_and_pick_none():
    first, second = device('Work Mac'), device('Home Mac')
    asleep, pocket = device('Old Mac', online=False, seen=NOW - 3600), device('Sam iPhone', 'ios')
    found = routed([first, asleep, second, pocket])
    assert found.device is None and found.code == 'needs_choice'
    assert found.candidates == (first, second)
    assert 'Work Mac' in found.message and 'Home Mac' in found.message and 'Mac, online, last seen now' in found.message
    assert 'Old Mac' not in found.message and 'Sam iPhone' not in found.message
    assert 'once' in found.message and '`device`' in found.message and 'device_id' in found.message


@pytest.mark.parametrize('label', ['Home Mac', 'home mac', '  HOME   Mac '])
def test_the_typing_device_wins_a_tie_when_kind_and_name_both_match(label):
    first, second = device('Work Mac'), device('Home Mac')
    assert routed([first, second], typing=typed('mac', label)).device is second


@pytest.mark.parametrize('typing', [
    None, ('mac', 'Other Mac'), ('ios', 'Home Mac'), ('desktop', 'Home Mac'), ('mac', 'Home'),
], ids=['unknown', 'kind-only', 'name-only', 'desktop-app', 'name-prefix'])
def test_a_partial_or_missing_typing_match_still_asks(typing):
    views = [device('Work Mac'), device('Home Mac')]
    found = routed(views, typing=None if typing is None else typed(*typing))
    assert found.device is None and found.code == 'needs_choice' and found.candidates == tuple(views)


def test_two_ready_devices_sharing_the_typing_name_and_kind_still_ask():
    views = [device('Mac', device_id='id-one'), device('mac', device_id='id-two')]
    found = routed(views, typing=typed('mac', 'Mac'))
    assert found.device is None and found.code == 'needs_choice' and found.candidates == tuple(views)


def test_the_typing_kind_separates_two_devices_that_share_a_name():
    pocket, work = device('Sam', 'ios'), device('Sam', 'mac')
    assert routed([pocket, work], REMIND, typed('ios', 'Sam')).device is pocket
    assert routed([pocket, work], REMIND, typed('mac', 'Sam')).device is work


@pytest.mark.parametrize('origin', [
    device('Origin Mac', online=False, seen=NOW - 60),
    device('Origin Mac', connectors={}),
    device('Origin Mac', 'ios', connectors={'shell': State.ALLOWED}),
], ids=['offline', 'capability-off', 'wrong-kind'])
def test_an_ineligible_typing_device_does_not_break_a_tie(origin):
    ready = [device('Work Mac'), device('Home Mac')]
    found = routed([origin, *ready], typing=typed(origin.kind, origin.label))
    assert found.device is None and found.code == 'needs_choice' and found.candidates == tuple(ready)


def test_with_none_available_the_refusal_names_the_action_and_why_for_every_device():
    asleep = device('Old Mac', online=False, seen=NOW - 3 * 3600)
    pocket = device('Sam iPhone', 'ios')
    stopped = device('Work Mac', connectors={})
    views = [asleep, pocket, stopped]
    found = routed(views, SHELL)
    assert found.device is None and found.code == 'no_device_available' and found.candidates == tuple(views)
    text = found.message
    assert 'shell.run' in text and 'Run commands' in text and 'nothing was started' in text.casefold()
    rows = {view.label: next(row for row in text.split('; ') if view.label in row) for view in views}
    assert 'Mac' in rows['Old Mac'] and f'offline since {last_seen_text(asleep, NOW)}' in rows['Old Mac']
    assert '3h ago' in rows['Old Mac'] and 'lacks' not in rows['Old Mac']
    assert 'iPhone' in rows['Sam iPhone'] and 'online' in rows['Sam iPhone']
    assert 'lacks Run commands' in rows['Sam iPhone'] and 'switched it off' not in rows['Sam iPhone']
    assert 'online' in rows['Work Mac'] and 'lacks Run commands' in rows['Work Mac']
    assert 'switched it off' in text and 'do not ask again unless they bring it up' in text.casefold()
    assert text.count('switched it off') == 1


def test_an_offline_device_with_the_capability_off_says_both():
    stopped = device('Work Mac', online=False, seen=NOW - 120, connectors={})
    text = routed([stopped], CLICK).message
    assert 'offline since' in text and '2m ago' in text and 'lacks Mouse and keyboard' in text
    assert 'switched it off' in text


def test_with_no_devices_the_refusal_says_none_is_logged_in():
    found = routed([], SHELL)
    assert found.code == 'no_device_available' and found.candidates == ()
    assert 'no device is logged in' in found.message.casefold() and 'shell.run' in found.message
    assert 'Run commands' in found.message and 'nothing was started' in found.message.casefold()
