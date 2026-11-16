"""Remote (dashboard websocket) operators read Kanban; writes stay native-only."""
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_state_runtime import RuntimeStoreError

GATEWAY_ID = 'gw-instance'
PROFILE_ID = '/profiles/owner'
READS = ('kanban.boards.list', 'kanban.board.snapshot', 'kanban.card.get', 'kanban.evidence.list', 'kanban.events.since')


def _connection(identity, *, operator=True, profile_id=PROFILE_ID):
    from gateway.session_controls import AuthorityConnection
    authority = SimpleNamespace(profile_id=profile_id, instance_id=GATEWAY_ID, retiring=False, runner=None, events={})
    ws_identity = {**identity, 'profile_scope': 'host'}
    return AuthorityConnection(authority, SimpleNamespace(), ws_identity, operator=operator)


def _dashboard_identity(**extra):
    return {'user_id': 'owner@example.test', 'provider': 'github', 'issuer': 'https://idp.example.test', **extra}


@pytest.fixture
def seeded(tmp_path, monkeypatch):
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    monkeypatch.setenv('HERMES_KANBAN_HOME', str(tmp_path))
    kb.init_db()
    kb.create_board('ops', name='Ops')
    with kbc.connect_closing(board='ops') as conn:
        task_id = kb.create_task(conn, title='remote card', assignee='owner', board='ops')
    return SimpleNamespace(root=tmp_path, task_id=task_id)


def _params(method, seeded, **extra):
    base = {'kanban.boards.list': {}, 'kanban.board.snapshot': {'board': 'ops'},
            'kanban.card.get': {'board': 'ops', 'task_id': seeded.task_id},
            'kanban.evidence.list': {'board': 'ops', 'task_id': seeded.task_id},
            'kanban.events.since': {'board': 'ops'}}[method]
    return {**base, **extra}


async def _call(connection, method, params):
    from gateway import session_kanban_read
    return await session_kanban_read.handlers(connection)[method](None, params)


@pytest.mark.asyncio
async def test_remote_operator_reads_seeded_board(seeded):
    connection = _connection(_dashboard_identity())
    assert not connection.native_owner
    listing = await _call(connection, 'kanban.boards.list', {})
    assert listing['gateway_id'] == GATEWAY_ID and 'ops' in {b['scope']['board'] for b in listing['boards']}
    snapshot = await _call(connection, 'kanban.board.snapshot', {'board': 'ops'})
    assert [c['task_id'] for c in snapshot['cards']] == [seeded.task_id]
    card = await _call(connection, 'kanban.card.get', _params('kanban.card.get', seeded))
    assert card['detail']['lifecycle']['status'] in ('todo', 'ready')
    assert (await _call(connection, 'kanban.evidence.list', _params('kanban.evidence.list', seeded)))['evidence'] == []
    assert 'events' in await _call(connection, 'kanban.events.since', {'board': 'ops'})


@pytest.mark.asyncio
@pytest.mark.parametrize('label,connection', [
    ('no session:read', lambda: _connection(_dashboard_identity(capabilities=['session:submit']))),
    ('server-internal', lambda: _connection({'user_id': 'server-internal', 'provider': 'server-internal'})),
    ('not operator', lambda: _connection(_dashboard_identity(), operator=False)),
    ('no identity', lambda: _connection({})),
    ('instance mismatch', lambda: _connection(_dashboard_identity(instance_id='another-gateway'))),
])
@pytest.mark.parametrize('method', READS)
async def test_remote_read_fails_closed(seeded, label, connection, method):
    with pytest.raises(RuntimeStoreError) as refused:
        await _call(connection(), method, _params(method, seeded))
    assert refused.value.reason == 'permission_denied', label


@pytest.mark.asyncio
@pytest.mark.parametrize('method', READS)
async def test_remote_operator_scope_is_own_profile_and_gateway(seeded, method):
    connection = _connection(_dashboard_identity())
    with pytest.raises(RuntimeStoreError) as other_profile:
        await _call(connection, method, _params(method, seeded, profile='someone-else'))
    assert other_profile.value.reason == 'profile_mismatch'
    with pytest.raises(RuntimeStoreError) as wrong_gateway:
        await _call(connection, method, _params(method, seeded, gateway_id='not-this-gateway'))
    assert wrong_gateway.value.reason == 'gateway_mismatch'


@pytest.mark.asyncio
async def test_remote_read_of_absent_board_never_creates_it(seeded):
    connection = _connection(_dashboard_identity())
    before = sorted(str(p) for p in Path(seeded.root).rglob('*'))
    snapshot = await _call(connection, 'kanban.board.snapshot', {'board': 'ghost'})
    assert snapshot['state'] == 'board_absent'
    assert sorted(str(p) for p in Path(seeded.root).rglob('*')) == before


@pytest.mark.asyncio
async def test_remote_operator_cannot_create_run_or_claim(seeded):
    from gateway.session_kanban import build_kanban_policy, run_task
    connection = _connection(_dashboard_identity())
    assert 'session:create' in connection.actor.capabilities and not connection.native_owner
    claim = {'board': 'ops', 'task_id': seeded.task_id, 'run_id': 1, 'claim_lock': 'x'}
    for call in (lambda: run_task(connection, claim), lambda: build_kanban_policy(connection, claim, {})):
        with pytest.raises(RuntimeStoreError) as refused:
            result = call()
            if hasattr(result, '__await__'):
                await result
        assert refused.value.reason == 'permission_denied'


@pytest.mark.asyncio
async def test_real_api_ws_dial_reads_board_and_refuses_writes(seeded, capsys):
    import asyncio
    import json
    from websockets.asyncio.client import connect
    from gateway.config import GatewayConfig
    from gateway.control_socket import GatewayControlServer
    from gateway.run import GatewayRunner
    from gateway.run_runtime import initialize_gateway_runtime, publish_gateway_runtime_ready, start_gateway_runtime_api
    from gateway.runtime_ownership import process_ownership
    from hermes_cli import web_server as web
    from hermes_constants import get_hermes_home

    (get_hermes_home() / 'config.yaml').write_text(json.dumps({
        'model': {'provider': 'custom', 'default': 'local-wire-stub', 'base_url': 'http://127.0.0.1:1/v1'},
        'platform_toolsets': {'cli': []}, 'auxiliary': {'title_generation': {'enabled': False}}}))
    process_ownership.reserve([get_hermes_home()])
    runner = GatewayRunner(GatewayConfig())
    try:
        await initialize_gateway_runtime(runner)
        runner.session_control_server = GatewayControlServer()
        assert await runner.session_control_server.start()
        await start_gateway_runtime_api(runner)
        assert await runner.start()
        publish_gateway_runtime_ready(runner)
        url = runner.session_api.api_origin.replace('http:', 'ws:') + '/api/ws?token=' + web._SESSION_TOKEN

        async def rpc(ws, rid, method, params):
            await ws.send(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
            async with asyncio.timeout(15):
                while True:
                    reply = json.loads(await ws.recv())
                    if reply.get('id') == rid:
                        return reply

        async with connect(url) as ws:
            listing = await rpc(ws, 1, 'kanban.boards.list', {})
            snapshot = await rpc(ws, 2, 'kanban.board.snapshot', {'board': 'ops'})
            run = await rpc(ws, 3, 'kanban.run', {'board': 'ops', 'task_id': seeded.task_id, 'run_id': 1, 'claim_lock': 'x'})
        with capsys.disabled():
            print('\nPROOF boards.list', json.dumps(listing)[:600])
            print('PROOF board.snapshot', json.dumps(snapshot)[:900])
            print('PROOF kanban.run', json.dumps(run))
        assert 'ops' in {b['scope']['board'] for b in listing['result']['boards']}
        assert [c['task_id'] for c in snapshot['result']['cards']] == [seeded.task_id]
        assert run['error']['data']['reason'] == 'permission_denied'
    finally:
        await runner.stop()
        await runner.session_control_server.stop()
        process_ownership.close()
