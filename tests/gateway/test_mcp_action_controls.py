"""``mcp.actions.auto_approve.*``: the owner's per-chat switch for an action-gated MCP server.

Invariants: only an app attached to the chat with ``session:approve`` can read or set it; only the owner's own
app chats (iOS, desktop, bot chat) and only action-gated servers are eligible; it starts off, lives in memory
for that chat alone and dies with the chat's approval state.
"""

import pytest

from gateway.session_controls import AuthorityConnection
from hermes_cli import mcp_catalog
from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner
from tools import approval, mcp_action_gate


def _config():
    return {'model': {'default': 'm'}, 'mcp_servers': {
        'upwork': mcp_catalog._build_server_config(mcp_catalog.get_entry('upwork'), None),
        'plain': {'url': 'https://plain.example/mcp'}}}


async def _rpc(connection, method, **params):
    return await connection.dispatch({'id': method, 'method': method, 'params': params})


@pytest.fixture
def owner(tmp_path, monkeypatch):
    store, _runner, authority, connection = _owner(tmp_path / 'home', monkeypatch, _config())
    yield tmp_path, authority, connection
    store.close_all_db_handles()


@pytest.mark.asyncio
@pytest.mark.parametrize('source', ['ios', 'gui'])
async def test_an_owner_app_chat_can_turn_it_on_for_that_chat_only(owner, source):
    tmp_path, authority, connection = owner
    live, _ = await _create(connection, authority, 'one', tmp_path, source=source)
    sid = next(k for k, v in authority.sessions.items() if v is live)
    try:
        assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=sid, server='upwork'))['result'] == {
            'enabled': False, 'eligible': True}
        assert (await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork', enabled=True))[
            'result'] == {'enabled': True}
        assert mcp_action_gate.auto_approve_enabled(live.route, 'upwork')
        assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=sid, server='upwork'))['result'] == {
            'enabled': True, 'eligible': True}
        again, _ = await _create(connection, authority, 'two', tmp_path, source=source)
        other = next(k for k, v in authority.sessions.items() if v is again)
        assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=other, server='upwork'))['result'][
            'enabled'] is False, 'a new chat starts off'
        approval.clear_session(live.route)
        assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=sid, server='upwork'))['result'][
            'enabled'] is False, 'the chat ending clears it'
        await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork', enabled=True)
        assert (await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork', enabled=False))[
            'result'] == {'enabled': False}
        assert not mcp_action_gate.auto_approve_enabled(live.route, 'upwork')
    finally:
        mcp_action_gate.clear_session(live.route)


@pytest.mark.asyncio
@pytest.mark.parametrize('source', ['tui', 'cli'])
async def test_a_terminal_chat_is_not_eligible_and_cannot_set_it(owner, source):
    tmp_path, authority, connection = owner
    live, _ = await _create(connection, authority, 'term', tmp_path, source=source)
    sid = next(k for k, v in authority.sessions.items() if v is live)
    assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=sid, server='upwork'))['result'] == {
        'enabled': False, 'eligible': False}
    refused = await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork', enabled=True)
    assert refused['error']['data']['reason'] == 'permission_denied'
    assert not mcp_action_gate.auto_approve_enabled(live.route, 'upwork')


@pytest.mark.asyncio
@pytest.mark.parametrize('server', ['plain', 'ghost'])
async def test_a_server_without_the_action_gate_is_not_eligible(owner, server):
    tmp_path, authority, connection = owner
    live, _ = await _create(connection, authority, 'one', tmp_path, source='ios')
    sid = next(k for k, v in authority.sessions.items() if v is live)
    assert (await _rpc(connection, 'mcp.actions.auto_approve.get', session_id=sid, server=server))['result'] == {
        'enabled': False, 'eligible': False}
    refused = await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server=server, enabled=True)
    assert refused['error']['data']['reason'] == 'permission_denied'


@pytest.mark.asyncio
async def test_a_connection_not_attached_to_the_chat_cannot_read_or_set_it(owner):
    tmp_path, authority, connection = owner
    live, _ = await _create(connection, authority, 'one', tmp_path, source='ios')
    sid = next(k for k, v in authority.sessions.items() if v is live)
    stranger = AuthorityConnection(authority, object(), {'user_id': 'someone-else'})
    for method, extra in (('get', {}), ('set', {'enabled': True})):
        reply = await _rpc(stranger, f'mcp.actions.auto_approve.{method}', session_id=sid, server='upwork', **extra)
        assert reply['error']['data']['reason'] == 'permission_denied'
    assert not mcp_action_gate.auto_approve_enabled(live.route, 'upwork')


@pytest.mark.asyncio
async def test_the_wire_takes_exactly_the_declared_fields(owner):
    tmp_path, authority, connection = owner
    live, _ = await _create(connection, authority, 'one', tmp_path, source='ios')
    sid = next(k for k, v in authority.sessions.items() if v is live)
    reply = await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork', enabled=True, tools=['x'])
    assert reply['error']['code'] == 4001
    reply = await _rpc(connection, 'mcp.actions.auto_approve.set', session_id=sid, server='upwork')
    assert reply['error']['code'] == 4001
