"""``session.search``: canonical message search for the native Search screen."""
import asyncio
import threading
from types import SimpleNamespace

import pytest
import pytest_asyncio

from gateway.session_controls import AuthorityConnection
from tests.gateway.test_local_source_labels import _authority


def _connection(authority, **identity):
    return AuthorityConnection(authority, SimpleNamespace(write=lambda frame: None),
                               {'user_id': 'owner', **identity})


async def _search(conn, **params):
    return await conn.dispatch({'id': 1, 'method': 'session.search', 'params': params})


def _seed(db, session_id, text, *, source='cli', title=None, hidden=False, role='user'):
    db.create_session(session_id, source=source)
    if title:
        db.set_session_title(session_id, title)
    db.append_message(session_id, role, text)
    if hidden:
        db.set_session_hidden(session_id, True)


@pytest_asyncio.fixture
async def conn(tmp_path, monkeypatch):
    authority, _store = await _authority(tmp_path, monkeypatch)
    connection = _connection(authority)
    yield connection
    await connection.close()
    authority.db.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('params', [
    {}, {'query': ''}, {'query': '   '}, {'query': 'x' * 201}, {'query': ' ' + 'x' * 201 + ' '},
    {'query': 5}, {'query': None}, {'query': ['a']}, {'query': 'ok', 'extra': 1},
    {'query': 'ok', 'limit': True}, {'query': 'ok', 'limit': '5'}, {'query': 'ok', 'limit': 2.5},
])
async def test_invalid_params_are_refused(conn, params):
    reply = await _search(conn, **params)
    assert reply['error']['message'] == 'invalid_params', reply


@pytest.mark.asyncio
async def test_query_is_trimmed_and_two_hundred_chars_are_accepted(conn):
    _seed(conn.authority.db, 'edge', 'boundary')
    assert (await _search(conn, query='  boundary  '))['result']['results'][0]['session_id'] == 'edge'
    assert (await _search(conn, query='y' * 200))['result'] == {'results': []}


@pytest.mark.asyncio
async def test_a_token_without_session_read_is_refused(tmp_path, monkeypatch):
    authority, _store = await _authority(tmp_path, monkeypatch)
    weak = _connection(authority, capabilities=['session:submit'])
    try:
        _seed(authority.db, 'private', 'secret marker')
        reply = await _search(weak, query='secret')
        assert reply['error']['message'] == 'permission_denied'
        assert 'secret' not in str(reply)
    finally:
        await weak.close()
        authority.db.close()


@pytest.mark.asyncio
async def test_a_foreign_profile_is_refused_for_a_profile_bound_token(conn):
    _seed(conn.authority.db, 'mine', 'secret marker')
    reply = await _search(conn, query='secret', profile='someone-else')
    assert reply['error']['message'] == 'profile_mismatch'
    assert 'result' in await _search(conn, query='secret', profile=None)


@pytest.mark.asyncio
async def test_limit_defaults_to_twenty_and_clamps_to_fifty(conn):
    for index in range(60):
        _seed(conn.authority.db, f'bulk-{index:02d}', f'needle number {index}')
    assert len((await _search(conn, query='needle'))['result']['results']) == 20
    assert len((await _search(conn, query='needle', limit=500))['result']['results']) == 50
    assert len((await _search(conn, query='needle', limit=0))['result']['results']) == 1
    assert len((await _search(conn, query='needle', limit=-3))['result']['results']) == 1
    assert len((await _search(conn, query='needle', limit=7))['result']['results']) == 7


@pytest.mark.asyncio
@pytest.mark.parametrize('query', [
    '"', '"unbalanced', 'a:b', 'title:needle', 'NEAR(', 'needle NEAR/3 x', '*', 'need*', '(', ')', '-', 'needle AND',
    'OR', 'NOT needle', 'x" OR "y', "it's", 'a\\b', '^needle', '{needle}', 'needle;DROP TABLE messages', '%', '_',
])
async def test_fts_syntax_characters_never_fail_the_search(conn, query):
    _seed(conn.authority.db, 'plain', 'needle in a haystack')
    reply = await _search(conn, query=query)
    assert isinstance(reply['result']['results'], list), reply


@pytest.mark.asyncio
async def test_quoted_phrase_and_prefix_still_match(conn):
    _seed(conn.authority.db, 'phrase', 'the quick brown fox')
    for query in ('"quick brown"', 'qui', 'quick fox'):
        assert [row['session_id'] for row in (await _search(conn, query=query))['result']['results']] == ['phrase']


@pytest.mark.asyncio
async def test_no_match_answers_an_empty_list(conn):
    _seed(conn.authority.db, 'other', 'something else entirely')
    assert (await _search(conn, query='zzzznomatch'))['result'] == {'results': []}


@pytest.mark.asyncio
async def test_hit_shape_is_plain_text_with_the_matching_message_time(conn):
    db = conn.authority.db
    long_text = ('lead ' * 400) + 'MARKER <b>bold</b> ' + ('tail ' * 400)
    _seed(db, 'shape', long_text, title='Shape title')
    hit = (await _search(conn, query='MARKER'))['result']['results'][0]
    assert set(hit) == {'session_id', 'resolved_id', 'title', 'snippet', 'role', 'timestamp', 'profile'}
    assert hit['session_id'] == 'shape' and hit['resolved_id'] == 'shape'
    assert hit['title'] == 'Shape title' and hit['role'] == 'user'
    assert hit['profile'] == 'default'
    assert isinstance(hit['timestamp'], float) and hit['timestamp'] > 0
    assert 'MARKER' in hit['snippet']
    for markup in ('>>>', '<<<', '<b>', '</b>', '\n'):
        assert markup not in hit['snippet']
    assert len(hit['snippet']) <= 240


@pytest.mark.asyncio
async def test_a_session_id_match_has_no_role_or_message_time(conn):
    _seed(conn.authority.db, '20260603_090200_abcdef', 'unrelated body')
    hit = (await _search(conn, query='20260603_090200'))['result']['results'][0]
    assert hit['session_id'] == '20260603_090200_abcdef'
    assert hit['role'] is None and hit['timestamp'] is None and hit['snippet']


@pytest.mark.asyncio
async def test_hidden_and_internal_sessions_never_surface(conn):
    db = conn.authority.db
    _seed(db, 'visible', 'shared needle visible')
    _seed(db, 'hidden-chat', 'shared needle hidden', hidden=True)
    _seed(db, 'kanban-worker', 'shared needle kanban', source='kanban')
    _seed(db, 'tool-run', 'shared needle tool', source='tool')
    _seed(db, 'one-shot', 'shared needle oneshot', source='oneshot')
    found = [row['session_id'] for row in (await _search(conn, query='shared needle'))['result']['results']]
    assert found == ['visible']
    by_title = [row['session_id'] for row in (await _search(conn, query='hidden-chat'))['result']['results']]
    assert by_title == []


@pytest.mark.asyncio
async def test_the_hidden_canonical_bot_chat_is_searchable_but_other_hidden_titles_are_not(conn):
    db = conn.authority.db
    _seed(db, 'bot-chat', 'orbit needle bot chat', title='Bot Chat', hidden=True)
    _seed(db, 'side-chat', 'orbit needle side chat', title='Side Chat', hidden=True)
    found = [row['session_id'] for row in (await _search(conn, query='orbit needle'))['result']['results']]
    assert found == ['bot-chat']


@pytest.mark.asyncio
async def test_a_compressed_lineage_answers_once_with_its_tip(conn):
    db = conn.authority.db
    _seed(db, 'lineage-root', 'lineage needle first segment')
    db.end_session('lineage-root', 'compression')
    db.create_session('lineage-tip', source='cli', parent_session_id='lineage-root')
    db.append_message('lineage-tip', 'assistant', 'lineage needle continued')
    hits = (await _search(conn, query='lineage needle'))['result']['results']
    assert len(hits) == 1
    assert hits[0]['resolved_id'] == 'lineage-tip'


@pytest.mark.asyncio
async def test_search_runs_off_the_event_loop(conn):
    _seed(conn.authority.db, 'threaded', 'threaded needle')
    loop_thread, seen = threading.get_ident(), []
    original = conn.authority.db.search_messages

    def recording(*args, **kwargs):
        seen.append(threading.get_ident())
        return original(*args, **kwargs)

    conn.authority.db.search_messages = recording
    hits = (await _search(conn, query='threaded'))['result']['results']
    assert hits and seen and loop_thread not in seen


@pytest.mark.asyncio
async def test_concurrent_searches_do_not_block_each_other(conn):
    _seed(conn.authority.db, 'many', 'concurrent needle')
    replies = await asyncio.gather(*(_search(conn, query='concurrent') for _ in range(5)))
    assert all(reply['result']['results'][0]['session_id'] == 'many' for reply in replies)


@pytest.mark.asyncio
async def test_each_profile_searches_only_its_own_store(tmp_path, monkeypatch):
    from gateway.run_runtime import initialize_gateway_runtime
    from gateway.runtime_ownership import process_ownership
    from gateway.session_authorities import authority_for_profile_id, owner_scope
    from tests.gateway.test_session_authorities_multiplex import _reserve_homes, _runner
    root, homes = _reserve_homes(tmp_path, monkeypatch)
    process_ownership.reserve([home for _, home in homes])
    connections, runner = [], None
    try:
        runner = _runner(root, homes)
        await initialize_gateway_runtime(runner)
        alpha_id, beta_id = (str(home.resolve()) for _, home in homes[1:])
        authority_for_profile_id(runner, beta_id).db.create_session('beta-private', source='cli')
        authority_for_profile_id(runner, beta_id).db.append_message('beta-private', 'user', 'PRIVATE_BETA_MARKER')
        authority_for_profile_id(runner, alpha_id).db.create_session('alpha-own', source='cli')
        authority_for_profile_id(runner, alpha_id).db.append_message('alpha-own', 'user', 'PRIVATE_ALPHA_MARKER')

        def connect(profile_id, **extra):
            authority = authority_for_profile_id(runner, profile_id)
            identity = {'user_id': 'uid:owner', 'provider': 'local', 'profile_id': profile_id,
                        'instance_id': authority.instance_id, **extra}
            with owner_scope(authority):
                connection = AuthorityConnection(authority, SimpleNamespace(write=lambda frame: None),
                                                 identity, operator=True)
            connections.append(connection)
            return connection

        async def call(connection, **params):
            with owner_scope(connection.authority):
                return await _search(connection, **params)

        alpha = connect(alpha_id)
        assert (await call(alpha, query='PRIVATE_BETA_MARKER'))['result'] == {'results': []}
        own = (await call(alpha, query='PRIVATE_ALPHA_MARKER'))['result']['results']
        assert [row['session_id'] for row in own] == ['alpha-own'] and own[0]['profile'] == 'alpha'
        for foreign in ('beta', 'default', 'gamma'):
            reply = await call(alpha, query='PRIVATE_BETA_MARKER', profile=foreign)
            assert reply['error']['message'] == 'profile_mismatch', reply
            assert 'PRIVATE_BETA_MARKER' not in str(reply)
        assert [row['session_id'] for row in (await call(alpha, query='PRIVATE_ALPHA_MARKER', profile='alpha'))
                ['result']['results']] == ['alpha-own']

        host = connect(str(root.resolve()), profile_scope='host')
        routed = (await call(host, query='PRIVATE_BETA_MARKER', profile='beta'))['result']['results']
        assert [row['session_id'] for row in routed] == ['beta-private'] and routed[0]['profile'] == 'beta'
        assert (await call(host, query='PRIVATE_BETA_MARKER'))['result'] == {'results': []}
        assert (await call(host, query='PRIVATE_BETA_MARKER', profile='gamma'))['error']['message'] == 'profile_mismatch'
    finally:
        for connection in connections:
            with owner_scope(connection.authority):
                await connection.close()
        for authority in list(getattr(runner, 'session_authorities', []) or []):
            authority.db.close()
        for _, home in homes:
            process_ownership.release(home)
