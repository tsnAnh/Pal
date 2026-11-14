"""A client opening a long chat resumes with ``message_limit`` and pages the older rows with
``session.history.page`` instead of receiving the whole transcript in one reply.

Real store, authority, local session and ``AuthorityConnection.dispatch`` (which checks every reply against
the canonical contract); the runner is a stand-in with no cached agent.
"""
from types import SimpleNamespace

import pytest

STORED = 300


async def _connection(tmp_path, monkeypatch):
    from gateway import run, session_local
    from gateway.config import GatewayConfig
    from gateway.session import SessionStore
    from gateway.session_authority import initialize_session_authority
    from gateway.session_contract import SessionActor
    from gateway.session_controls import AuthorityConnection
    from hermes_state_local import local_receipt
    monkeypatch.setattr(run, '_load_gateway_config', dict)
    monkeypatch.setattr(session_local, 'local_session_info', lambda *a: {'desktop_protocol': 'hermes-gateway-v1'})
    store = SessionStore(tmp_path / 'sessions', GatewayConfig())
    runner = SimpleNamespace(session_store=store, _session_db=store._db, adapters={}, _draining=False,
                             _cached_agent_for=lambda *a, **k: None, _evict_cached_agent=lambda *a, **k: None)
    runner._adapter_for_source = lambda source: runner.adapters.get(source.platform)
    authority = await initialize_session_authority(runner, profile_id='fixture', instance_id='first')
    actor = SessionActor('owner', 'fixture', frozenset({'session:create', 'session:read', 'session:control'}), 'sock')
    ref = session_local.create_local_session(authority, actor, dict(
        request_id='resume', source='gui', cwd=str(tmp_path), model='frozen', toolsets=[]))
    physical = local_receipt(authority.db, ref.session_id)['entry']['session_id']
    for n in range(STORED // 2):
        authority.db.append_message(physical, 'user', f'Q{n}')
        authority.db.append_message(physical, 'assistant', f'A{n}')
    conn = AuthorityConnection(authority, object(), {'user_id': 'owner'})
    conn.actor = actor
    authority.events[actor.transport_id] = object()

    async def call(method, **params):
        reply = await conn.dispatch({'jsonrpc': '2.0', 'id': 1, 'method': method,
                                     'params': {'session_id': ref.session_id, **params}})
        assert 'error' not in reply, reply
        return reply['result']
    return call


def _texts(rows):
    return [row.get('text') or row.get('content') for row in rows]


@pytest.mark.asyncio
async def test_windowed_resume_returns_the_newest_rows_and_counts_the_rest(tmp_path, monkeypatch):
    call = await _connection(tmp_path, monkeypatch)
    snapshot = await call('session.resume', message_limit=50)
    assert _texts(snapshot['messages']) == _texts([{'text': f'{r}{n}'} for n in range(125, 150) for r in 'QA'])
    assert snapshot['older_messages'] == STORED - 50
    assert snapshot['message_count'] == STORED


@pytest.mark.asyncio
async def test_paging_back_walks_to_the_first_row_without_gaps_or_repeats(tmp_path, monkeypatch):
    call = await _connection(tmp_path, monkeypatch)
    full = (await call('session.resume'))['messages']
    snapshot = await call('session.resume', message_limit=50)
    rows, older = list(snapshot['messages']), snapshot['older_messages']
    while older:
        page = await call('session.history.page', before_row_id=rows[0]['row_id'], limit=60)
        assert page['messages'], page
        rows, older = page['messages'] + rows, page['older_messages']
    assert [row['row_id'] for row in rows] == [row['row_id'] for row in full]
    assert len(full) == STORED


@pytest.mark.asyncio
async def test_resume_without_a_limit_still_returns_the_whole_transcript(tmp_path, monkeypatch):
    call = await _connection(tmp_path, monkeypatch)
    snapshot = await call('session.resume')
    assert len(snapshot['messages']) == STORED == snapshot['message_count']
    assert snapshot.get('older_messages') is None
