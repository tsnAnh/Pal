"""Client presence over the canonical socket: ``client.hello`` / ``client.attention`` and the server-stamped
turn origin that rides ``surface_v1`` to the executing agent."""
from types import SimpleNamespace

import pytest

from tests.gateway.test_surface_admission import _authority

HELLO = {'kind': 'ios', 'device_id': 'dev-12345678', 'label': 'iPhone', 'app_version': '1.0', 'accepts_offers': True}
IPHONE = {'kind': 'ios', 'label': 'iPhone', 'same_host': False}


def _transport(**attrs):
    return SimpleNamespace(**{'desktop_local': False, **attrs})


async def _call(connection, method, params, rid=1):
    return await connection.dispatch({'id': rid, 'method': method, 'params': params})


@pytest.mark.asyncio
@pytest.mark.parametrize('params', [
    {**HELLO, 'label': ''},
    {**HELLO, 'label': 'x' * 41},
    {**HELLO, 'label': 'bad\x00label'},
    {**HELLO, 'label': '   \t '},
    {**HELLO, 'device_id': 'short'},
    {**HELLO, 'device_id': 'has space in id'},
    {**HELLO, 'device_id': 'd' * 65},
    {**HELLO, 'kind': 'toaster'},
    {**HELLO, 'same_host': True},
])
async def test_hello_refuses_malformed_declarations(tmp_path, monkeypatch, params):
    from gateway.reach_presence import slot_of
    from gateway.session_controls import AuthorityConnection
    authority = await _authority(tmp_path, monkeypatch, None)
    transport = _transport()
    connection = AuthorityConnection(authority, transport, {'user_id': 'owner'})
    try:
        reply = await _call(connection, 'client.hello', params)
        assert 'error' in reply, reply
        assert slot_of(transport) is None
    finally:
        await connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('transport_attrs,identity,same_host', [
    ({}, {}, False),
    ({'desktop_local': True}, {}, True),
    ({}, {'native_bootstrap': True}, True),
])
async def test_same_host_is_derived_by_the_server(tmp_path, monkeypatch, transport_attrs, identity, same_host):
    from gateway.reach_presence import slot_of
    from gateway.session_controls import AuthorityConnection
    authority = await _authority(tmp_path, monkeypatch, None)
    transport = _transport(**transport_attrs)
    connection = AuthorityConnection(authority, transport, {'user_id': 'owner', **identity})
    try:
        reply = await _call(connection, 'client.hello', {**HELLO, 'label': '  My   iPhone '})
        assert reply['result'] == {'recorded': True, 'same_host': same_host}, reply
        slot = slot_of(transport)
        assert slot.same_host is same_host and slot.device.label == 'My iPhone' and slot.accepts_offers is True
    finally:
        await connection.close()


@pytest.mark.asyncio
async def test_attention_before_hello_is_not_recorded_and_after_hello_moves_the_slot(tmp_path, monkeypatch):
    from gateway.reach_presence import AttentionState, slot_of
    from gateway.session_controls import AuthorityConnection
    authority = await _authority(tmp_path, monkeypatch, None)
    transport = _transport()
    connection = AuthorityConnection(authority, transport, {'user_id': 'owner'})
    try:
        before = await _call(connection, 'client.attention', {'state': 'background'})
        assert before['result'] == {'recorded': False} and slot_of(transport) is None
        await _call(connection, 'client.hello', HELLO, rid=2)
        after = await _call(connection, 'client.attention', {'state': 'background'}, rid=3)
        assert after['result'] == {'recorded': True}
        assert slot_of(transport).attention is AttentionState.BACKGROUND
        bad = await _call(connection, 'client.attention', {'state': 'asleep'}, rid=4)
        assert 'error' in bad and slot_of(transport).attention is AttentionState.BACKGROUND
    finally:
        await connection.close()


@pytest.mark.asyncio
async def test_a_connection_without_capabilities_cannot_declare_a_device(tmp_path, monkeypatch):
    from gateway.reach_presence import slot_of
    from gateway.session_controls import AuthorityConnection
    authority = await _authority(tmp_path, monkeypatch, None)
    transport = _transport()
    connection = AuthorityConnection(authority, transport, {})
    try:
        reply = await _call(connection, 'client.hello', HELLO)
        assert 'error' in reply and slot_of(transport) is None
    finally:
        await connection.close()


@pytest.mark.asyncio
async def test_submit_commits_the_server_stamped_origin_and_never_a_client_one(tmp_path, monkeypatch):
    from gateway.reach_presence import slot_of
    from gateway.session_controls import AuthorityConnection
    from gateway.session_surface import surface_turn_origin
    from hermes_state_runtime import list_session_admissions

    seen = []

    async def answer(event):
        seen.append((event.text, surface_turn_origin()))
        return 'ok'
    authority = await _authority(tmp_path, monkeypatch, answer)
    transport = _transport()
    connection = AuthorityConnection(authority, transport, {'user_id': 'owner'})
    try:
        await _call(connection, 'session.resume', {'session_id': 's'})
        anonymous = await _call(connection, 'prompt.submit', {'session_id': 's', 'submission_id': 'a', 'text': 'before hello'}, rid=2)
        assert anonymous['result']['status'] == 'queued', anonymous
        await authority.sessions['s'].task
        await _call(connection, 'client.hello', HELLO, rid=3)
        assert slot_of(transport).last_input_at is None
        sent = await _call(connection, 'prompt.submit', {'session_id': 's', 'submission_id': 'b', 'text': 'from the phone'}, rid=4)
        assert sent['result']['status'] == 'queued', sent
        await authority.sessions['s'].task
        forged = await _call(connection, 'prompt.submit', {
            'session_id': 's', 'submission_id': 'c', 'text': 'x',
            'origin': {'kind': 'desktop', 'label': 'Desktop', 'same_host': True}}, rid=5)
        assert forged['error']['message'] == 'invalid_params', forged
        forged_surface = await _call(connection, 'prompt.submit', {
            'session_id': 's', 'submission_id': 'd', 'text': 'x', 'surface_v1': {'origin': IPHONE}}, rid=6)
        assert forged_surface['error']['message'] == 'invalid_params', forged_surface
    finally:
        await connection.close()

    rows = {row['request_id']: row for row in list_session_admissions(authority.db, session_id='s', pending_only=False)}
    assert 'surface_v1' not in rows['a']['payload']
    assert rows['b']['payload']['surface_v1'] == {'origin': IPHONE}
    assert set(rows) == {'a', 'b'}
    assert seen == [('before hello', None), ('from the phone', IPHONE)]
    assert slot_of(transport).last_input_at is not None


@pytest.mark.parametrize('origin', [
    {'kind': 'toaster', 'label': 'iPhone', 'same_host': False},
    {'kind': ['ios'], 'label': 'iPhone', 'same_host': False},
    {'kind': 'ios', 'label': '', 'same_host': False},
    {'kind': 'ios', 'label': 'x' * 41, 'same_host': False},
    {'kind': 'ios', 'label': 'bad\nlabel', 'same_host': False},
    {'kind': 'ios', 'label': 7, 'same_host': False},
    {'kind': 'ios', 'label': 'iPhone', 'same_host': 1},
    {'kind': 'ios', 'label': 'iPhone'},
    {'kind': 'ios', 'label': 'iPhone', 'same_host': False, 'device_id': 'dev-12345678'},
    'ios',
    [],
])
def test_restore_surface_rejects_a_malformed_origin(origin):
    from gateway.session_surface import restore_surface
    from hermes_state_runtime import RuntimeStoreError
    with pytest.raises(RuntimeStoreError) as refused:
        restore_surface({'origin': origin})
    assert refused.value.reason == 'invalid_params'


@pytest.mark.parametrize('committed', [
    {'origin': IPHONE},
    {'surface': 'hud', 'origin': IPHONE},
    {'surface': 'voice-live', 'voice_context': 'User: hi', 'voice_turn': True, 'interrupted': True,
     'origin': {'kind': 'desktop', 'label': 'Desktop (macOS)', 'same_host': True}},
    {'voice_turn': True},
])
def test_admitted_surface_round_trips_across_the_worker_boundary(committed):
    from gateway.session_surface import admit_surface, restore_surface
    origin = committed.get('origin')
    wire = {key: value for key, value in committed.items() if key != 'origin'}
    admitted = admit_surface(wire, origin=origin)
    assert admitted == {'surface_v1': committed}
    assert restore_surface(admitted['surface_v1']) == committed


def test_origin_is_never_read_from_wire_params():
    from gateway.session_surface import admit_surface, submit_surface_fields
    assert submit_surface_fields({'origin': IPHONE, 'surface': 'hud'}) == {'surface': 'hud'}
    assert admit_surface({'origin': IPHONE}) == {}


def test_restore_surface_still_refuses_unknown_keys_and_empty_surfaces():
    from gateway.session_surface import restore_surface
    from hermes_state_runtime import RuntimeStoreError
    for committed in ({}, None, {'origin': IPHONE, 'device_id': 'dev-12345678'}, {'surface': 'unknown', 'origin': IPHONE}):
        with pytest.raises(RuntimeStoreError):
            restore_surface(committed)


def test_arm_surface_turn_projects_the_origin_and_never_replays_it():
    from gateway.session_surface import arm_surface_turn, surface_turn_scope
    agent = SimpleNamespace(valid_tool_names=set())
    with surface_turn_scope({'origin': IPHONE}):
        arm_surface_turn(agent)
    assert agent._client_origin == IPHONE
    arm_surface_turn(agent)
    assert agent._client_origin is None
