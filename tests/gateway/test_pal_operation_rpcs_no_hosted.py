"""A Pal (`ios`) session drives its own connection operations on the session authority without the hosted connector stack.

The authority serves Desktop and Pal from one process; the hosted gate applies to an operation of the
hosted kind only. Every module that talks to the Nous portal is replaced by a sentinel.
"""

from __future__ import annotations

import contextlib
import json
from types import SimpleNamespace

import pytest

from tests.tools.nous_sentinels import install_sentinels
from tools.connectors import live
from tools.connectors.contract import Actor, TargetState
from tools.connectors.operation import ConnectionOperation, Target


def build_owner(home, monkeypatch):
    from gateway import run
    from gateway.config import GatewayConfig
    from gateway.session import SessionStore
    from gateway.session_authority import SessionAuthority
    from gateway.session_controls import AuthorityConnection
    from tests.gateway.test_session_create_tier_cwd import storage_handle

    home.mkdir(parents=True, exist_ok=True)
    (home / 'config.yaml').write_text(json.dumps({'model': {'default': 'm'}}))
    monkeypatch.setenv('HERMES_HOME', str(home))
    monkeypatch.setattr(run, '_hermes_home', home)
    store = SessionStore(home / 'sessions', GatewayConfig())
    db = store.persistence
    runner = SimpleNamespace(session_store=store, _session_db=db, adapters={}, _draining=False,
                             _evict_cached_agent=lambda route: None, _cached_agent_for=lambda route: None,
                             _handle_message=None, _peek_session_state=lambda key: None,
                             _session_env_scope=lambda context: contextlib.nullcontext())
    runner._adapter_for_source = lambda source: runner.adapters.get(source.platform)
    authority = SessionAuthority(runner, profile_id=str(home), instance_id='owner', persistence=storage_handle(home),
                                 epoch=db.runtime.begin_epoch(instance_id='owner'))
    runner.session_authority = authority
    return store, authority, AuthorityConnection(authority, object(), {'user_id': 'human'})


async def create_session(owner, authority, name, tmp_path, **extra):
    response = await owner.dispatch({'id': name, 'method': 'session.create', 'params': dict(
        request_id=name, cwd=str(tmp_path), model='m', **extra)})
    assert 'result' in response, response
    return response['result']['session_id'], authority.sessions[response['result']['session_id']].route


reruns: list[list[str]] = []


def retry_target(operation, names):
    reruns.append(list(names))
    operation.transition('linear', TargetState.initiated, Actor.user)


async def call(connection, method, **params):
    return await connection.dispatch({'id': method, 'method': method, 'params': params})


@pytest.mark.asyncio
async def test_a_pal_session_drives_its_mcp_operation_and_retries_a_failed_row_without_touching_a_nous_module(
        tmp_path, monkeypatch):
    store, authority, owner = build_owner(tmp_path / 'home', monkeypatch)
    live._open.clear()
    try:
        sid, route = await create_session(owner, authority, 'phone', tmp_path, source='ios')
        operation = ConnectionOperation([Target('linear', 'mcp', 'install'), Target('notion', 'mcp', 'install')],
                                        session_key=route)
        live.open(operation)
        who = {'type': 'session', 'session_id': sid}
        monkeypatch.setattr('tools.connectors.mcp.retry', retry_target)
        nous_sentinels = install_sentinels(monkeypatch)

        status = await call(owner, 'connectors.operation.status', owner=who, op_id=operation.op_id)
        assert status['result']['op_id'] == operation.op_id

        operation.wake.clear()
        woke = await call(owner, 'connectors.operation.wake', owner=who, op_id=operation.op_id)
        assert woke['result'] == {'status': 'ok'} and operation.wake.is_set()

        skipped = await call(owner, 'connection.respond', owner=who, op_id=operation.op_id,
                             result={'targets': [{'name': 'notion', 'status': 'skipped'}]})
        assert skipped['error']['data']['reason'] == 'INVALID_ANSWER', skipped
        assert operation.target('notion').state == TargetState.pending

        operation.transition('linear', TargetState.failed, Actor.backend_watcher)
        retried = await call(owner, 'connectors.connect', owner=who, connectors=['linear'], reconnect=True)
        assert retried['result']['targets'][0]['state'] == 'initiated', retried
        assert reruns == [['linear']]

        assert nous_sentinels == []
    finally:
        live._open.clear()
        await owner.close()
        store.close_all_db_handles()
