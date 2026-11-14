import asyncio
import json

import pytest

from gateway import device_mcp_relay
from tests.gateway.device_mcp_harness import (
    call_echo, connect_mac, mcp_tool_names, registered, servers_in_config, wait_for_tools)
from tests.gateway.device_tools_harness import connect_phone, device_id_for, home_of
from tests.waiting import async_wait_until
from tools import mcp_tool_device
from tui_gateway.contracts.canonical_device import DeviceMcpServer

pytest_plugins = ('tests.gateway.device_tools_harness', 'tests.gateway.device_mcp_harness')


def reason_of(reply) -> str:
    return reply['error']['data']['reason']


async def serving(authority, text='ready') -> bool:
    return f'echo:{text}' in json.dumps(await call_echo(authority, text))


async def wait_until_serving(authority, what='the server answering again'):
    await async_wait_until(lambda: serving(authority), what=what, timeout=30)


class RecordingChannel:
    def __init__(self):
        self.messages, self.failures = [], []

    def post_message(self, message):
        self.messages.append(message)
        return True

    def post_failure(self, error):
        self.failures.append(error)
        return True


async def open_recorded(authority):
    channel = RecordingChannel()
    relay = await device_mcp_relay._open_on_owner(
        authority, home_of(authority), 't3code', device_id_for('Mac'), DeviceMcpServer.T3CODE, channel)
    return relay, channel


@pytest.mark.asyncio
async def test_registering_t3code_writes_config_and_its_tools_work_end_to_end(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    assert servers_in_config(authority)['t3code'] == {
        'transport': 'device', 'device_id': device_id_for('Mac'), 'server': 't3code'}
    await wait_for_tools(authority)
    assert 'echo:hi' in json.dumps(await call_echo(authority, 'hi'))
    assert len(mac.relays()) == 1 and mac.methods()[:2] == ['initialize', 'notifications/initialized']


@pytest.mark.asyncio
async def test_registering_again_changes_nothing_and_another_mac_takes_the_server_over(authorities):
    authority = await authorities('home')
    first = await connect_mac(authority, 'Mac-one')
    await registered(first, authority)
    await wait_for_tools(authority)
    before = servers_in_config(authority)
    await registered(first, authority)
    assert servers_in_config(authority) == before and len(first.relays()) == 1
    second = await connect_mac(authority, 'Mac-two')
    await registered(second, authority)
    assert servers_in_config(authority)['t3code']['device_id'] == device_id_for('Mac-two')
    await async_wait_until(lambda: [c['reason'] for c in first.closed] == ['unregistered'], what='old relay closed')
    await wait_until_serving(authority)
    assert second.relays()


@pytest.mark.asyncio
@pytest.mark.parametrize('method', ['device.mcp.register', 'device.mcp.unregister'])
async def test_a_phone_cannot_offer_a_server_and_nothing_is_written(authorities, method):
    authority = await authorities('home')
    phone = await connect_phone(authority, 'iPhone', kind='ios')
    reply = await phone.call(method, {'server': 't3code'})
    assert reason_of(reply) == 'permission_denied'
    assert servers_in_config(authority) == {} and not device_mcp_relay._relays


@pytest.mark.asyncio
async def test_a_connection_that_never_declared_device_tools_cannot_register(authorities):
    authority = await authorities('home')
    bare = await connect_phone(authority, 'Bare', kind='mac', device_tools=False)
    assert reason_of(await bare.call('device.mcp.register', {'server': 't3code'})) == 'invalid_params'
    assert servers_in_config(authority) == {}


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params', [
    ('device.mcp.register', {'server': 'terminal'}),
    ('device.mcp.unregister', {'server': 'filesystem'}),
    ('device.mcp.deliver', {'relay_id': 'relay-0001', 'message': 'not an object'}),
    ('device.mcp.deliver', {'relay_id': 'x', 'message': {}}),
    ('device.mcp.fail', {'relay_id': 'relay-0001', 'code': 'exploded'}),
])
async def test_the_contract_refuses_unknown_servers_and_malformed_relay_calls(authorities, method, params):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    reply = await mac.phone.call(method, params)
    assert 'error' in reply, reply
    assert servers_in_config(authority) == {}


@pytest.mark.asyncio
async def test_only_the_connection_that_owns_a_relay_can_deliver_into_it_or_fail_it(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    intruder = await connect_mac(authority, 'Other-Mac')
    relay, channel = await open_recorded(authority)
    message = {'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {'data': 'x'}}
    assert (await intruder.deliver(relay.relay_id, message))['result'] == {'accepted': False}
    assert (await intruder.fail(relay.relay_id, 'closed'))['result'] == {'recorded': False}
    assert channel.messages == [] and channel.failures == [] and relay.relay_id in device_mcp_relay._relays
    assert (await mac.deliver(relay.relay_id, message))['result'] == {'accepted': True}
    assert channel.messages == [message]
    assert (await mac.deliver('relay-unknown-1', message))['result'] == {'accepted': False}


@pytest.mark.asyncio
async def test_a_relay_failure_reaches_the_bot_clipped_and_ends_the_relay(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    relay, channel = await open_recorded(authority)
    reply = await mac.fail(relay.relay_id, 'unreachable', 'T3 is not running\x07' + 'x' * 1000)
    assert reply['result'] == {'recorded': True}
    [error] = channel.failures
    assert isinstance(error, mcp_tool_device.DeviceUnreachableError)
    assert len(str(error)) <= 300 and '\x07' not in str(error)
    assert relay.relay_id not in device_mcp_relay._relays
    assert (await mac.deliver(relay.relay_id, {'jsonrpc': '2.0', 'method': 'ping'}))['result'] == {'accepted': False}


@pytest.mark.asyncio
async def test_a_mac_that_is_offline_cannot_be_connected_to(authorities):
    authority = await authorities('home')
    await connect_mac(authority)
    with pytest.raises(mcp_tool_device.DeviceUnreachableError):
        await device_mcp_relay._open_on_owner(
            authority, home_of(authority), 't3code', device_id_for('Gone-Mac'), DeviceMcpServer.T3CODE,
            RecordingChannel())


@pytest.mark.asyncio
async def test_a_mac_that_disconnects_mid_call_fails_the_call_and_serves_again_when_it_returns(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    mac.muted = True
    stuck = asyncio.ensure_future(call_echo(authority, 'never answered'))
    await async_wait_until(lambda: 'tools/call' in mac.methods(), what='the call reached the Mac')
    await mac.phone.connection.close()
    result = await asyncio.wait_for(stuck, 60)
    assert 'error' in result and not device_mcp_relay._relays
    back = await connect_mac(authority)
    await registered(back, authority)
    await wait_until_serving(authority)
    assert back.relays()


@pytest.mark.asyncio
async def test_t3_stopping_mid_call_is_reported_with_the_reason_the_mac_gave(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    mac.muted = True
    stuck = asyncio.ensure_future(call_echo(authority, 'cut off'))
    await async_wait_until(lambda: 'tools/call' in mac.methods(), what='the call reached the Mac')
    assert (await mac.fail(mac.relays()[-1], 'unreachable', "T3 Code isn't running on this Mac"))['result'] == {
        'recorded': True}
    result = await asyncio.wait_for(stuck, 60)
    assert "T3 Code isn't running on this Mac" in result['error']
    assert 'stdio' not in result['error'] and 'subprocess' not in result['error']


@pytest.mark.asyncio
async def test_the_server_serves_again_when_t3_returns_even_after_calls_kept_failing_meanwhile(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    mac.down = True
    for attempt in range(4):
        result = await call_echo(authority, f'while down {attempt}')
        assert 'error' in result
    closed_while_down = len(mac.closed)
    mac.down = False
    await registered(mac, authority)
    await wait_until_serving(authority, 'the server answering after T3 returned')
    assert len(mac.closed) == closed_while_down


@pytest.mark.asyncio
async def test_a_lost_t3_sign_in_surfaces_as_an_auth_required_result_for_mcp_t3code(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    mac.muted = True
    stuck = asyncio.ensure_future(call_echo(authority, 'rejected'))
    await async_wait_until(lambda: 'tools/call' in mac.methods(), what='the call reached the Mac')
    assert (await mac.fail(mac.relays()[-1], 'auth_required', 'T3 returned 401'))['result'] == {'recorded': True}
    [offer] = await async_wait_until(lambda: mac.phone.events('auth.required'), what='the sign-in prompt')
    assert offer['service'] == 'mcp:t3code' and offer['flow'] == 'oauth' and offer['signin_on'] == 'owner_app'
    in_flight = await asyncio.wait_for(stuck, 60)
    assert 'T3 returned 401' in in_flight['error']
    blocked = asyncio.ensure_future(call_echo(authority, 'again'))
    await asyncio.sleep(0)
    await mac.phone.call('auth.decline', {'request_id': offer['request_id']})
    result = await asyncio.wait_for(blocked, 60)
    assert result['auth_required'] == {'service': 'mcp:t3code'} and result['error_type'] == 'auth_declined'


@pytest.mark.asyncio
async def test_registering_again_after_signing_in_ends_the_prompt_and_the_server_serves_again(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    await mac.fail(mac.relays()[-1], 'auth_required', 'token expired')
    [offer] = await async_wait_until(lambda: mac.phone.events('auth.required'), what='the sign-in prompt')
    assert mcp_tool_device.pending_auth_reason(home_of(authority), 't3code') == 'expired'
    relays_before = len(mac.relays())
    await registered(mac, authority)
    [resolved] = await async_wait_until(lambda: mac.phone.events('auth.resolved'), what='the prompt ended')
    assert resolved['request_id'] == offer['request_id'] and resolved['outcome'] == 'signed_in'
    assert mcp_tool_device.pending_auth_reason(home_of(authority), 't3code') is None
    await wait_until_serving(authority)
    assert len(mac.relays()) > relays_before


@pytest.mark.asyncio
async def test_the_gateway_does_not_reconnect_a_rejected_sign_in_until_the_mac_registers_again(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    await mac.fail(mac.relays()[-1], 'auth_required', 'token expired')
    await async_wait_until(lambda: mac.phone.events('auth.required'), what='the sign-in prompt')
    frames_after_failure = len(mac.served)
    with pytest.raises(mcp_tool_device.DeviceAuthRequiredError):
        async with mcp_tool_device.device_transport(home_of(authority), 't3code', device_id_for('Mac'), 't3code'):
            pass
    assert len(mac.served) == frames_after_failure


@pytest.mark.asyncio
async def test_a_request_over_4_mib_is_refused_with_a_clear_error_and_never_sent(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    result = await call_echo(authority, 'x' * (mcp_tool_device.MAX_MESSAGE_BYTES + 1))
    assert 'too large' in result['error']
    assert all(mcp_tool_device.encoded_size(payload['message']) <= mcp_tool_device.MAX_MESSAGE_BYTES
               for payload in mac.served)
    assert 'echo:ok' in json.dumps(await call_echo(authority, 'ok')) and len(mac.relays()) == 1


@pytest.mark.asyncio
async def test_a_message_over_4_mib_from_the_mac_fails_that_relay_and_a_fresh_one_serves(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    first = mac.relays()[-1]
    huge = {'jsonrpc': '2.0', 'method': 'notifications/message',
            'params': {'level': 'info', 'data': 'x' * (mcp_tool_device.MAX_MESSAGE_BYTES + 1)}}
    assert (await mac.deliver(first, huge))['result'] == {'accepted': False}
    assert first not in device_mcp_relay._relays
    await async_wait_until(lambda: any(c['relay_id'] == first for c in mac.closed), what='close frame')
    await wait_until_serving(authority)
    assert mac.relays()[-1] != first


@pytest.mark.asyncio
async def test_unregistering_ends_live_relays_removes_the_config_and_the_tools(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    relay = mac.relays()[-1]
    reply = await mac.unregister()
    assert reply['result'] == {'registered': False, 'name': 't3code'}
    assert servers_in_config(authority) == {}
    await async_wait_until(lambda: {'relay_id': relay, 'reason': 'unregistered'} in mac.closed, what='close frame')
    await async_wait_until(lambda: mcp_tool_names(authority) == [], what='tools removed', timeout=30)
    assert not device_mcp_relay._relays
    assert (await mac.unregister())['result'] == {'registered': False, 'name': 't3code'}


@pytest.mark.asyncio
async def test_only_the_mac_that_registered_a_server_can_unregister_it(authorities):
    authority = await authorities('home')
    owner = await connect_mac(authority, 'Mac-one')
    await registered(owner, authority)
    other = await connect_mac(authority, 'Mac-two')
    assert reason_of(await other.unregister()) == 'permission_denied'
    assert servers_in_config(authority)['t3code']['device_id'] == device_id_for('Mac-one')


@pytest.mark.asyncio
async def test_a_name_already_used_by_another_kind_of_server_is_not_overwritten(authorities):
    authority = await authorities('home')
    (home_of(authority) / 'config.yaml').write_text('mcp_servers:\n  t3code:\n    url: https://other.example/mcp\n')
    mac = await connect_mac(authority)
    assert reason_of(await mac.register()) == 'invalid_params'
    assert servers_in_config(authority)['t3code'] == {'url': 'https://other.example/mcp'}


@pytest.mark.asyncio
@pytest.mark.parametrize('config', [
    {'url': 'https://mac.example/mcp', 'transport': 'device'},
    {'transport': 'device', 'device_id': 'device-Mac-0000', 'server': 't3code'},
])
async def test_the_socket_cannot_create_a_device_server(authorities, config):
    authority = await authorities('home')
    phone = await connect_phone(authority, 'iPhone', kind='ios')
    reply = await phone.call('mcp.servers.add', {'name': 't3code', 'config': config})
    assert reason_of(reply) == 'invalid_params' and reply['error']['data']['field'] == 'config'
    edit = await phone.call('mcp.servers.update', {'name': 't3code', 'config': {'transport': 'device'}})
    assert reason_of(edit) == 'invalid_params'
    assert servers_in_config(authority) == {}


@pytest.mark.asyncio
async def test_a_registration_changes_only_its_own_bots_config_and_relays_stay_in_that_bot(authorities):
    alpha, beta = await authorities('alpha'), await authorities('beta')
    alpha_mac, beta_mac = await connect_mac(alpha, 'Alpha-Mac'), await connect_mac(beta, 'Beta-Mac')
    await registered(alpha_mac, alpha)
    await wait_for_tools(alpha)
    assert 'echo:hi' in json.dumps(await call_echo(alpha, 'hi'))
    assert servers_in_config(beta) == {} and beta_mac.served == []
    assert {relay.home for relay in device_mcp_relay._relays.values()} == {home_of(alpha).resolve()}


@pytest.mark.asyncio
async def test_many_concurrent_calls_over_one_relay_each_get_their_own_answer(authorities):
    authority = await authorities('home')
    mac = await connect_mac(authority)
    await registered(mac, authority)
    await wait_for_tools(authority)
    texts = [f'call-{n}' for n in range(8)]
    results = await asyncio.gather(*(call_echo(authority, text) for text in texts))
    assert [f'echo:{text}' in json.dumps(result) for text, result in zip(texts, results)] == [True] * len(texts)
    assert len(mac.relays()) == 1
