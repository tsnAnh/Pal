"""Native Kanban reads through the real ticket WebSocket of a real gateway process; the capability matrix test uses stand-in connections (test double)."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sqlite3
from types import SimpleNamespace

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from tests.gateway.kanban_native_read_support import (
    NativeSocket, isolated_env, native_socket, running_gateway, ticket, write_gateway_config,
)

PROFILE = 'projbot'
SESSION = 'sess-1'
SECRET_PATH = '/home/canary-user/secret-workspace'
EXPECTED_METHODS = {'kanban.boards.list', 'kanban.board.snapshot', 'kanban.card.get', 'kanban.evidence.list',
                    'kanban.events.since'}


def _add_file(conn, kb, task_id, directory: Path, name='app.zip', data=b'build-bytes'):
    path = directory / name
    path.write_bytes(data)
    kb.add_attachment(conn, task_id, filename=name, stored_path=str(path), size=len(data))
    return hashlib.sha256(data).hexdigest()


def _lifecycle(kb, conn, task_id, evidence, *, directory, complete=True):
    from hermes_cli.kanban_external_claim import claim_external
    from hermes_cli.kanban_outcomes_store import record_evidence
    run_id = claim_external(conn, task_id, profile=PROFILE, session_id=SESSION, board='ops').current_run_id
    for kind, payload in evidence:
        record_evidence(conn, task_id, run_id=run_id, kind=kind, payload=payload, profile=PROFILE)
    if complete:
        kb.complete_task(conn, task_id, summary='done', expected_run_id=run_id, actor_profile=PROFILE)
    return run_id


def _seed(kanban_home: Path, scratch: Path) -> dict:
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    from hermes_cli import kanban_db_workspace as kbw
    os.environ['HERMES_KANBAN_HOME'] = str(kanban_home)
    kb.init_db()
    kb.create_board('ops', name='Ops', dispatch_mode='external')
    kb.create_board('lab', name='Lab')
    kb.create_board('retired')
    kb.remove_board('retired', archive=True)
    sha = 'd' * 64
    ids = {}
    with kbc.connect_closing(board='ops') as conn:
        def card(title, contract):
            return kb.create_task(conn, title=title, assignee=PROFILE, outcome_contract=contract, board='ops')
        ids['built'], ids['installed'] = card('built card', {'kind': 'built_artifact'}), card('installed card', {'kind': 'installed_app'})
        ids['other'], ids['wip'] = (card('other card', {'kind': 'other', 'name': 'report', 'required_fields': ['url']}),
                                    card('wip card', {'kind': 'built_artifact'}))
        ids['plain'] = kb.create_task(conn, title='ungoverned card', assignee=PROFILE, board='ops')
        ids['child'] = kb.create_task(conn, title='waits on wip', assignee=PROFILE, parents=(ids['wip'],), board='ops')
        built_sha = _add_file(conn, kb, ids['built'], scratch)
        ids['built_run'] = _lifecycle(kb, conn, ids['built'], [
            ('execution_ref', {'session_id': SESSION, 'runtime': 'pi'}),
            ('artifact_built', {'sha256': built_sha, 'name': 'app.zip'})], directory=scratch)
        ids['installed_run'] = _lifecycle(kb, conn, ids['installed'], [
            ('artifact_built', {'sha256': sha, 'name': 'app.zip'}),
            ('app_installed', {'app_id': 'dev.pal', 'artifact_sha256': sha, 'readback_sha256': sha, 'host': 'mac-mini'})],
            directory=scratch)
        ids['other_run'] = _lifecycle(kb, conn, ids['other'], [
            ('other_result', {'name': 'report', 'receipt': {'url': 'https://example.test/r', 'note': f'wrote {SECRET_PATH}/r.txt'}})],
            directory=scratch)
        ids['wip_run'] = _lifecycle(kb, conn, ids['wip'], [('execution_ref', {'session_id': SESSION, 'runtime': 'pi'})],
                                    directory=scratch, complete=False)
        kbw.set_workspace_path(conn, ids['wip'], SECRET_PATH)
        ids['lock'] = kb.get_task(conn, ids['wip']).claim_lock
        kb._append_event(conn, ids['wip'], 'spawned', {'pid': 4242, 'token': 'canary-token', 'path': SECRET_PATH},
                         run_id=ids['wip_run'])
        kb._append_event(conn, ids['plain'], 'pr_acceptance', {'ok': True, 'classification': 'green'})
    with kbc.connect_closing(board='lab') as lab:
        lab.execute("INSERT INTO tasks (id, title, status, created_at, workspace_kind) VALUES (?, 'same id, other board', 'ready', 1, 'scratch')",
                    (ids['built'],))
        lab.commit()
    return ids


@pytest.fixture(scope='module')
def gateway(tmp_path_factory):
    base = tmp_path_factory.mktemp('kanban-native-read')
    home, user, kanban_home, scratch = base / 'state', base / 'user', base / 'kanban-root', base / 'scratch'
    for path in (user, kanban_home, scratch):
        path.mkdir()
    home.mkdir(mode=0o700)
    write_gateway_config(home)
    previous = os.environ.get('HERMES_KANBAN_HOME')
    ids = _seed(kanban_home, scratch)
    env = isolated_env(home, user, kanban_home)
    try:
        with running_gateway(home, env) as descriptor:
            yield SimpleNamespace(home=home, descriptor=descriptor, ids=ids, kanban_home=kanban_home, base=base)
    finally:
        os.environ.pop('HERMES_KANBAN_HOME', None) if previous is None else os.environ.__setitem__('HERMES_KANBAN_HOME', previous)


def _board_db(gateway, slug):
    return gateway.kanban_home / 'kanban' / 'boards' / slug / 'kanban.db'


def _tree(root: Path):
    return sorted(str(p.relative_to(root)) for p in root.rglob('*'))


def _db_fingerprint(gateway):
    out = {}
    for slug in ('ops', 'lab'):
        with sqlite3.connect(_board_db(gateway, slug)) as conn:
            out[slug] = [conn.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]
                         for t in ('tasks', 'task_events', 'task_runs', 'task_evidence', 'task_links')]
            out[slug].append(conn.execute('SELECT group_concat(status) FROM (SELECT status FROM tasks ORDER BY id)').fetchone()[0])
    return out


@pytest.mark.asyncio
async def test_authorized_owner_reads_boards_snapshot_card_and_evidence(gateway):
    ids = gateway.ids
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        listing = await ws.result('kanban.boards.list')
        gid = listing['gateway_id']
        assert gid == gateway.descriptor['instance_id']
        boards = {b['scope']['board']: b for b in listing['boards']}
        assert set(boards) == {'default', 'ops', 'lab', 'retired'}
        assert boards['ops']['dispatch_mode'] == 'external' and boards['lab']['dispatch_mode'] == 'workers'
        assert boards['retired']['archived'] is True and boards['retired']['task_counts'] is None
        assert boards['ops']['scope']['board_id'] == f'{gid}/ops'

        snap = await ws.result('kanban.board.snapshot', board='ops', gateway_id=gid)
        assert snap['state'] == 'present' and snap['next_page_token'] is None and snap['cursor']
        cards = {c['task_id']: c for c in snap['cards']}
        assert set(cards) == {ids[k] for k in ('built', 'installed', 'other', 'wip', 'plain', 'child')}
        assert cards[ids['built']]['card_id'] == f"{gid}/ops/{ids['built']}" and cards[ids['plain']]['governed'] is False
        assert snap['prerequisites'] == [{'task_id': ids['child'], 'requires_task_id': ids['wip']}]
        assert cards[ids['child']]['status'] == 'todo' and cards[ids['built']]['status'] == 'done'

        detail = (await ws.result('kanban.card.get', board='ops', task_id=ids['built']))['detail']
        assert detail['lifecycle']['status'] == 'done'
        assert detail['execution']['runs'][0]['executor'] == 'external'
        assert detail['execution']['runs'][0]['executor_session'] == SESSION
        evidence = (await ws.result('kanban.evidence.list', board='ops', task_id=ids['built']))['evidence']
        assert [e['kind'] for e in evidence] == ['execution_ref', 'artifact_built']
        assert {e['producer_profile'] for e in evidence} == {PROFILE} and {e['producer_session'] for e in evidence} == {SESSION}
        assert {e['kind']: e['source'] for e in evidence}['artifact_built'] == 'local-file'
        only = await ws.result('kanban.evidence.list', board='ops', task_id=ids['built'], run_id=999)
        assert only['evidence'] == []


@pytest.mark.asyncio
async def test_lifecycle_ci_and_outcome_verification_stay_separate_and_attestations_stay_attested(gateway):
    ids = gateway.ids
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        async def detail(key):
            return (await ws.result('kanban.card.get', board='ops', task_id=ids[key]))['detail']
        built, installed, other, wip, plain = [await detail(k) for k in ('built', 'installed', 'other', 'wip', 'plain')]
        assert built['outcome_verification']['verification'] == 'independent'
        assert installed['outcome_verification']['verification'] == 'attested'
        assert other['outcome_verification']['verification'] == 'attested'
        assert installed['outcome_verification']['receipt']['host'] == 'mac-mini'
        assert {e['kind'] for e in installed['evidence']} == {'artifact_built', 'app_installed'}
        assert [e['source'] for e in installed['evidence'] if e['kind'] == 'app_installed'] == ['attestation']
        assert built['ci_acceptance']['state'] == 'unknown'
        assert wip['outcome_verification']['state'] == 'unknown' and wip['outcome_verification']['verification'] is None
        assert wip['lifecycle']['status'] == 'running' and wip['execution']['current_run_id'] == ids['wip_run']
        assert plain['outcome_contract'] is None and plain['outcome_verification']['state'] == 'not_governed'
        assert plain['ci_acceptance'] == {'state': 'accepted', 'classification': 'green', 'run_id': None,
                                          'observed_at': plain['ci_acceptance']['observed_at'],
                                          'event_id': plain['ci_acceptance']['event_id']}
        assert plain['lifecycle']['status'] != 'done'


@pytest.mark.asyncio
async def test_wire_never_carries_claim_locks_paths_or_unlisted_event_data(gateway):
    ids = gateway.ids
    frames = []
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        gid = (await ws.result('kanban.boards.list'))['gateway_id']
        frames.append(await ws.call('kanban.boards.list'))
        snap = await ws.call('kanban.board.snapshot', board='ops')
        frames.append(snap)
        for key in ('built', 'installed', 'other', 'wip', 'plain', 'child'):
            frames.append(await ws.call('kanban.card.get', board='ops', task_id=ids[key]))
            frames.append(await ws.call('kanban.evidence.list', board='ops', task_id=ids[key]))
        cursor = encode(gid, 'ops', snap['result']['cursor'], event_id=0)
        replay = await ws.call('kanban.events.since', board='ops', cursor=cursor, limit=500)
        frames.append(replay)
        kinds = {e['kind'] for e in replay['result']['events']}
    assert {'claimed', 'evidence_recorded', 'outcome_verified', 'spawned'} <= kinds
    wire = json.dumps(frames)
    for canary in (ids['lock'], 'canary-user', 'canary-token', str(gateway.home), str(gateway.kanban_home), 'kanban.db', 'claim_lock'):
        assert canary not in wire, canary
    claimed = next(e for e in replay['result']['events'] if e['kind'] == 'claimed')
    assert set(claimed['data']) <= {'executor', 'profile', 'session', 'run_id'}
    assert next(e for e in replay['result']['events'] if e['kind'] == 'spawned')['data'] == {}


def encode(gateway_id, board, cursor, *, event_id=None, generation=None, gateway=None):
    from hermes_cli import kanban_native_read as read
    _gw, _slug, gen, head, count = read._decode_cursor(cursor)
    return read.encode_cursor(gateway or gateway_id, board, generation or gen, head if event_id is None else event_id, count if event_id is None else min(count, event_id))


@pytest.mark.asyncio
async def test_same_task_id_on_two_boards_is_two_cards_and_cursors_do_not_cross(gateway):
    tid = gateway.ids['built']
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        ops = (await ws.result('kanban.card.get', board='ops', task_id=tid))['detail']
        lab = (await ws.result('kanban.card.get', board='lab', task_id=tid))['detail']
        assert ops['card']['card_id'] != lab['card']['card_id'] and ops['card']['title'] == 'built card'
        assert lab['card']['title'] == 'same id, other board' and lab['evidence'] == []
        gid = (await ws.result('kanban.boards.list'))['gateway_id']
        cursor = (await ws.result('kanban.board.snapshot', board='ops'))['cursor']
        crossed = await ws.result('kanban.events.since', board='lab', cursor=cursor)
        assert (crossed['state'], crossed['reason']) == ('snapshot_required', 'wrong_board')
        foreign = encode(gid, 'ops', cursor, gateway='f' * 32)
        reply = await ws.result('kanban.events.since', board='ops', cursor=foreign)
        assert (reply['state'], reply['reason']) == ('snapshot_required', 'wrong_gateway')
        other_gateway = await ws.call('kanban.board.snapshot', board='ops', gateway_id='f' * 32)
        assert other_gateway['error']['message'] == 'gateway_mismatch'


@pytest.mark.asyncio
async def test_snapshot_cursor_replay_is_gapless_idempotent_and_survives_reconnect(gateway):
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    ids = gateway.ids
    os.environ['HERMES_KANBAN_HOME'] = str(gateway.kanban_home)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        snap = await ws.result('kanban.board.snapshot', board='ops')
        first_cursor = snap['cursor']
        assert (await ws.result('kanban.events.since', board='ops', cursor=first_cursor))['events'] == []
        with kbc.connect_closing(board='ops') as conn:
            for n in range(5):
                kb.add_comment(conn, ids['plain'], 'tester', f'note {n}')
        pages, cursor = [], first_cursor
        while True:
            page = await ws.result('kanban.events.since', board='ops', cursor=cursor, limit=2)
            pages.append(page)
            cursor = page['cursor']
            if not page['has_more']:
                break
        got = [e['event_id'] for p in pages for e in p['events']]
        assert len(got) == 5 and got == sorted(got) and got == list(range(got[0], got[0] + 5))
        assert [len(p['events']) for p in pages] == [2, 2, 1]
        full = await ws.result('kanban.events.since', board='ops', cursor=first_cursor, limit=500)
        assert [e['event_id'] for e in full['events']] == got
        assert full == await ws.result('kanban.events.since', board='ops', cursor=first_cursor, limit=500)
        assert (await ws.result('kanban.board.snapshot', board='ops'))['cursor'] == full['cursor'] == cursor
        only_plain = await ws.result('kanban.events.since', board='ops', cursor=first_cursor, task_id=ids['plain'])
        assert [e['event_id'] for e in only_plain['events']] == got
    async with native_socket(gateway.home, gateway.descriptor) as fresh:
        replay = await fresh.result('kanban.events.since', board='ops', cursor=first_cursor, limit=500)
        assert [e['event_id'] for e in replay['events']] == got


@pytest.mark.asyncio
async def test_unusable_cursors_demand_a_snapshot_instead_of_partial_results(gateway):
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        gid = (await ws.result('kanban.boards.list'))['gateway_id']
        cursor = (await ws.result('kanban.board.snapshot', board='ops'))['cursor']

        async def reason(**kw):
            reply = await ws.result('kanban.events.since', board='ops', **kw)
            assert reply['state'] == 'snapshot_required' and reply['events'] == [], reply
            return reply['reason']
        assert await reason() == 'cursor_required'
        assert await reason(cursor='not-a-cursor') == 'invalid_cursor'
        assert await reason(cursor=encode(gid, 'ops', cursor, generation='0' * 12)) == 'stale_generation'
        assert await reason(cursor=encode(gid, 'ops', cursor, event_id=10_000)) == 'ahead_of_log'


@pytest.mark.asyncio
async def test_absent_archived_and_hostile_requests_answer_typed_without_touching_disk(gateway):
    before_tree, before_db = _tree(gateway.kanban_home), _db_fingerprint(gateway)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        for method, extra in (('kanban.board.snapshot', {}), ('kanban.card.get', {'task_id': 'nope'}),
                              ('kanban.evidence.list', {'task_id': 'nope'}), ('kanban.events.since', {'cursor': 'x'})):
            assert (await ws.result(method, board='never-created', **extra))['state'] == 'board_absent'
            assert (await ws.result(method, board='retired', **extra))['state'] == 'board_archived'
        assert (await ws.result('kanban.card.get', board='ops', task_id='nope'))['state'] == 'card_absent'
        assert (await ws.result('kanban.evidence.list', board='ops', task_id='nope'))['state'] == 'card_absent'
        for board in ('../lab', '/etc', 'ops/../lab', 'OPS bad', '..', 'a' * 90):
            reply = await ws.call('kanban.board.snapshot', board=board)
            assert reply['error']['message'] == 'invalid_params', (board, reply)
        for hostile in ({'db': str(_board_db(gateway, 'lab'))}, {'profile': 'foreign-profile'}, {'path': '/etc/passwd'},
                        {'principal': 'someone-else'}):
            reply = await ws.call('kanban.board.snapshot', board='ops', **hostile)
            assert 'error' in reply and 'result' not in reply, (hostile, reply)
        assert (await ws.call('kanban.card.get', board='ops'))['error']['message'] == 'invalid_params'
    assert _tree(gateway.kanban_home) == before_tree and _db_fingerprint(gateway) == before_db


@pytest.mark.asyncio
async def test_reads_never_mutate_the_lifecycle_or_start_workers_even_when_retried(gateway):
    before_tree, before_db = _tree(gateway.kanban_home), _db_fingerprint(gateway)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        for _ in range(3):
            await ws.result('kanban.boards.list')
            snap = await ws.result('kanban.board.snapshot', board='ops')
            for card in snap['cards']:
                await ws.result('kanban.card.get', board='ops', task_id=card['task_id'])
                await ws.result('kanban.evidence.list', board='ops', task_id=card['task_id'])
            await ws.result('kanban.events.since', board='ops', cursor=snap['cursor'])
    assert _tree(gateway.kanban_home) == before_tree and _db_fingerprint(gateway) == before_db
    with sqlite3.connect(_board_db(gateway, 'ops')) as conn:
        assert conn.execute("SELECT COUNT(*) FROM task_events WHERE kind IN ('spawned', 'reclaimed') AND payload LIKE '%pid%' AND id > 1000").fetchone()[0] == 0
        assert conn.execute('SELECT COUNT(*) FROM tasks WHERE worker_pid IS NOT NULL').fetchone()[0] == 0
    from tui_gateway.contracts.registry import CANONICAL_METHODS
    assert {m for m in CANONICAL_METHODS if m.startswith('kanban.')} == EXPECTED_METHODS | {'kanban.run'}


@pytest.mark.asyncio
async def test_tickets_that_are_missing_forged_spent_or_for_another_purpose_read_nothing(gateway):
    url = gateway.descriptor['api_origin'].replace('http:', 'ws:') + '/api/ws'
    with pytest.raises(InvalidStatus):
        async with connect(url, subprotocols=['hermes-gateway-v1']):
            pass
    with pytest.raises(InvalidStatus):
        async with connect(url, subprotocols=['hermes-gateway-v1', 'hermes-gateway-ticket.forged']):
            pass
    protocols = ['hermes-gateway-v1', 'hermes-gateway-ticket.' + ticket(gateway.home, gateway.descriptor)]
    async with connect(url, subprotocols=protocols) as first:
        assert 'result' in await NativeSocket(first).call('kanban.boards.list')
    with pytest.raises(InvalidStatus):
        async with connect(url, subprotocols=protocols):
            pass
    try:
        async with native_socket(gateway.home, gateway.descriptor, purpose='worker-adoption') as worker:
            reply = await worker.call('kanban.boards.list')
    except InvalidStatus:
        return
    assert 'result' not in reply and reply['error']['message'] in ('permission_denied', 'unknown_method'), reply


@pytest.mark.asyncio
async def test_events_after_a_snapshot_are_gapless_while_another_process_writes(gateway):
    import threading
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    os.environ['HERMES_KANBAN_HOME'] = str(gateway.kanban_home)
    plain, stop, written = gateway.ids['plain'], threading.Event(), []

    def writer():
        with kbc.connect_closing(board='ops') as conn:
            for n in range(60):
                kb.add_comment(conn, plain, 'tester', f'race {n}')
                written.append(n)
            stop.set()
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        start = (await ws.result('kanban.board.snapshot', board='ops'))['cursor']
        thread = threading.Thread(target=writer)
        thread.start()
        seen, cursor = [], start
        while not stop.is_set() or len(seen) < 60:
            page = await ws.result('kanban.events.since', board='ops', cursor=cursor, limit=7)
            seen += [e['event_id'] for e in page['events']]
            cursor = page['cursor']
            await ws.result('kanban.board.snapshot', board='ops')
            assert len(seen) <= 60
        thread.join()
        from hermes_cli import kanban_native_read as read
        head = read._decode_cursor(cursor)[3]
        assert seen == list(range(read._decode_cursor(start)[3] + 1, head + 1)) and len(seen) == 60


@pytest.mark.asyncio
async def test_capability_matrix_with_stand_in_connections():
    from gateway import session_kanban_read as handlers_module
    from hermes_state_runtime import RuntimeStoreError

    def connection(*, native, capabilities, profile='p', actor_profile='p'):
        authority = SimpleNamespace(profile_id=profile, instance_id='gw', retiring=False, runner=None)
        return SimpleNamespace(native_owner=native, authority=authority,
                               actor=SimpleNamespace(profile_id=actor_profile, capabilities=frozenset(capabilities)))
    denied = {
        'non-native (dashboard or bot-origin)': connection(native=False, capabilities={'session:read'}),
        'worker-only grant': connection(native=True, capabilities={'worker:adopt'}),
        'revoked / no capability': connection(native=True, capabilities=set()),
        'another profile': connection(native=True, capabilities={'session:read'}, actor_profile='q'),
    }
    for label, conn in denied.items():
        for method, params in (('kanban.boards.list', {}), ('kanban.board.snapshot', {'board': 'ops'}),
                               ('kanban.card.get', {'board': 'ops', 'task_id': 't'}),
                               ('kanban.evidence.list', {'board': 'ops', 'task_id': 't'}),
                               ('kanban.events.since', {'board': 'ops'})):
            with pytest.raises(RuntimeStoreError) as refused:
                await handlers_module.handlers(conn)[method](None, params)
            assert refused.value.reason in ('permission_denied', 'profile_mismatch'), (label, method)


def _kanban_env(gateway):
    os.environ['HERMES_KANBAN_HOME'] = str(gateway.kanban_home)
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    return kb, kbc


def _fill_board(gateway, slug, count):
    kb, kbc = _kanban_env(gateway)
    kb.create_board(slug)
    with kbc.connect_closing(board=slug) as conn:
        ids = [kb.create_task(conn, title=f'card {n}', assignee=PROFILE, board=slug) for n in range(count)]
        child = kb.create_task(conn, title='late child', assignee=PROFILE, parents=(ids[0], ids[-1]), board=slug)
    return [*ids, child]


async def _pages(ws, board, limit, **kw):
    pages, token = [], None
    while True:
        page = await ws.result('kanban.board.snapshot', board=board, limit=limit, **({'page_token': token} if token else {}), **kw)
        pages.append(page)
        token = page['next_page_token']
        if token is None:
            return pages


@pytest.mark.asyncio
async def test_snapshot_enumerates_every_card_and_edge_across_pages_beyond_the_page_maximum(gateway):
    ids = _fill_board(gateway, 'big', 620)
    kb, kbc = _kanban_env(gateway)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        for limit in (500, 100, 10_000):
            pages = await _pages(ws, 'big', limit)
            cards = [c['task_id'] for p in pages for c in p['cards']]
            assert sorted(cards) == sorted(ids) and len(set(cards)) == len(ids), limit
            assert all(len(p['cards']) <= 500 for p in pages) and len(pages) >= 2
            assert [p['cursor'] is None for p in pages] == [True] * (len(pages) - 1) + [False]
            edges = {(e['task_id'], e['requires_task_id']) for p in pages for e in p['prerequisites']}
            assert edges == {(ids[-1], ids[0]), (ids[-1], ids[-2])}
        first = await ws.result('kanban.board.snapshot', board='big', limit=100)
        second = await ws.result('kanban.board.snapshot', board='big', limit=100, page_token=first['next_page_token'])
        assert second == await ws.result('kanban.board.snapshot', board='big', limit=100, page_token=first['next_page_token'])
        assert [c['task_id'] for c in second['cards']] == sorted(c['task_id'] for c in second['cards'])
        assert not {c['task_id'] for c in first['cards']} & {c['task_id'] for c in second['cards']}
        wrong = await ws.result('kanban.board.snapshot', board='ops', limit=100, page_token=first['next_page_token'])
        assert (wrong['state'], wrong['reason']) == ('snapshot_required', 'wrong_board')
        bad = await ws.result('kanban.board.snapshot', board='big', page_token='garbage')
        assert (bad['state'], bad['reason']) == ('snapshot_required', 'invalid_cursor')
        final = (await _pages(ws, 'big', 500))[-1]
        with kbc.connect_closing(board='big') as conn:
            late = kb.create_task(conn, title='after snapshot', assignee=PROFILE, board='big')
        replay = await ws.result('kanban.events.since', board='big', cursor=final['cursor'])
        assert [(e['task_id'], e['kind']) for e in replay['events']] == [(late, 'created')]


@pytest.mark.asyncio
async def test_a_snapshot_whose_board_changes_between_pages_restarts_instead_of_stitching(gateway):
    _fill_board(gateway, 'busy', 30)
    kb, kbc = _kanban_env(gateway)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        first = await ws.result('kanban.board.snapshot', board='busy', limit=10)
        with kbc.connect_closing(board='busy') as conn:
            kb.create_task(conn, title='written between pages', assignee=PROFILE, board='busy')
        stale = await ws.result('kanban.board.snapshot', board='busy', limit=10, page_token=first['next_page_token'])
        assert (stale['state'], stale['reason'], stale['cards']) == ('snapshot_required', 'changed_during_snapshot', [])
        restarted = await _pages(ws, 'busy', 10)
        assert sum(len(p['cards']) for p in restarted) == 32
        gid = (await ws.result('kanban.boards.list'))['gateway_id']
        other = await ws.result('kanban.board.snapshot', board='busy', limit=10, page_token=encode_token(first['next_page_token'], gateway='f' * 32))
        assert other['reason'] == 'wrong_gateway' and gid


def encode_token(token, *, gateway):
    from hermes_cli import kanban_native_read as read
    prefix, _gw, *rest = json.loads(__import__('base64').urlsafe_b64decode(token + '=' * (-len(token) % 4)))
    return read._pack(prefix, gateway, *rest)


@pytest.mark.asyncio
async def test_supported_purge_and_retention_invalidate_cursors_and_a_fresh_snapshot_is_sound(gateway):
    import time
    from tests.waiting import wait_until
    kb, kbc = _kanban_env(gateway)
    kb.create_board('purge')
    with kbc.connect_closing(board='purge') as conn:
        keep, doomed, after = (kb.create_task(conn, title=t, assignee=PROFILE, board='purge') for t in ('keep', 'doomed', 'after'))
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        clean = await ws.result('kanban.board.snapshot', board='purge')
        with kbc.connect_closing(board='purge') as conn:
            kb.add_comment(conn, keep, 'tester', 'seen by the client')
        assert (await ws.result('kanban.events.since', board='purge', cursor=clean['cursor']))['state'] == 'ok'
        cursor = (await ws.result('kanban.board.snapshot', board='purge'))['cursor']
        with kbc.connect_closing(board='purge') as conn:
            assert kb.delete_task(conn, doomed) is True
        stale = await ws.result('kanban.events.since', board='purge', cursor=cursor)
        assert (stale['state'], stale['reason'], stale['events']) == ('snapshot_required', 'history_changed', [])
        fresh = await ws.result('kanban.board.snapshot', board='purge')
        assert sorted(c['task_id'] for c in fresh['cards']) == sorted([keep, after])
        assert (await ws.result('kanban.events.since', board='purge', cursor=fresh['cursor']))['events'] == []

        gap_start = fresh['cursor']
        with kbc.connect_closing(board='purge') as conn:
            unseen = kb.create_task(conn, title='unseen', assignee=PROFILE, board='purge')
            kb.add_comment(conn, after, 'tester', 'after the hole')
            kb.complete_task(conn, unseen, summary='done')
            wait_until(lambda: int(time.time()) > max(e.created_at for e in kb.list_events(conn, unseen)), what='clock tick')
            assert kb.gc_events(conn, older_than_seconds=0) >= 2
        lost = await ws.result('kanban.events.since', board='purge', cursor=gap_start)
        assert (lost['state'], lost['reason'], lost['events']) == ('snapshot_required', 'gap', [])
        again = await ws.result('kanban.board.snapshot', board='purge')
        assert unseen in {c['task_id'] for c in again['cards']}
        assert (await ws.result('kanban.events.since', board='purge', cursor=again['cursor']))['events'] == []


@pytest.mark.asyncio
async def test_a_new_run_never_inherits_an_earlier_runs_proofs(gateway):
    from hermes_cli.kanban_external_claim import claim_external
    from hermes_cli.kanban_outcomes_store import OutcomeRefusedError
    kb, kbc = _kanban_env(gateway)
    kb.create_board('rerun', dispatch_mode='external')
    with kbc.connect_closing(board='rerun') as conn:
        task = kb.create_task(conn, title='retried', assignee=PROFILE, outcome_contract={'kind': 'built_artifact'}, board='rerun')
        run_1 = claim_external(conn, task, profile=PROFILE, session_id='s1', board='rerun').current_run_id
        with pytest.raises(OutcomeRefusedError):
            kb.complete_task(conn, task, summary='x', expected_run_id=run_1, actor_profile=PROFILE)
        kb._append_event(conn, task, 'pr_acceptance', {'ok': True, 'classification': 'green'}, run_id=run_1)
        assert kb.reclaim_task(conn, task, reason='retry')
        run_2 = claim_external(conn, task, profile=PROFILE, session_id='s2', board='rerun').current_run_id
    assert run_2 != run_1

    async def detail():
        async with native_socket(gateway.home, gateway.descriptor) as ws:
            return (await ws.result('kanban.card.get', board='rerun', task_id=task))['detail']
    current = await detail()
    assert current['proof_run_id'] == run_2 and current['execution']['current_run_id'] == run_2
    assert current['outcome_verification']['state'] == 'unknown' and current['outcome_verification']['run_id'] is None
    assert current['ci_acceptance']['state'] == 'unknown'
    assert {(h['kind'], h['run_id'], h['state']) for h in current['proof_history']} == {
        ('outcome_refused', run_1, 'refused'), ('pr_acceptance', run_1, 'accepted')}
    with kbc.connect_closing(board='rerun') as conn, pytest.raises(OutcomeRefusedError):
        kb.complete_task(conn, task, summary='x', expected_run_id=run_2, actor_profile=PROFILE)
    refused = await detail()
    assert (refused['outcome_verification']['state'], refused['outcome_verification']['run_id']) == ('refused', run_2)
    assert refused['ci_acceptance']['state'] == 'unknown'


@pytest.mark.asyncio
async def test_a_completed_card_cannot_be_reclaimed_so_a_verified_proof_never_goes_stale(gateway):
    from hermes_cli.kanban_external_claim import claim_external
    kb, kbc = _kanban_env(gateway)
    with kbc.connect_closing(board='ops') as conn:
        assert claim_external(conn, gateway.ids['built'], profile=PROFILE, session_id='again', board='ops') is None
        assert not kb.reclaim_task(conn, gateway.ids['built']) and not kb.unblock_task(conn, gateway.ids['built'])
        assert kb.get_task(conn, gateway.ids['built']).status == 'done'


def _token(*parts):
    import base64
    return base64.urlsafe_b64encode(json.dumps(parts[0] if len(parts) == 1 and isinstance(parts[0], list) else list(parts), separators=(',', ':')).encode()).decode().rstrip('=')


def _raw_token(raw: bytes):
    import base64
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


MALFORMED_TOKENS = {
    'object': _raw_token(b'{}'), 'object_with_zero_key': _raw_token(b'{"0":"c"}'), 'string': _raw_token(b'"c"'),
    'null': _raw_token(b'null'), 'number': _raw_token(b'7'), 'bool': _raw_token(b'true'), 'empty_array': _raw_token(b'[]'),
    'prefix_only': _raw_token(b'["c"]'), 'too_many': _raw_token(b'["c","a","b","c",1,2,3]'), 'string_element_is_int': _raw_token(b'["c",1,"b","c",1,2]'),
    'int_element_is_string': _raw_token(b'["c","a","b","c","1",2]'), 'negative': _raw_token(b'["c","a","b","c",-1,2]'),
    'bool_element': _raw_token(b'["c","a","b","c",true,2]'), 'float_element': _raw_token(b'["c","a","b","c",1.5,2]'),
    'wrong_prefix': _raw_token(b'["x","a","b","c",1,2]'), 'bad_json': _raw_token(b'[1,'), 'invalid_utf8': _raw_token(b'\xff\xfe'),
    'not_base64': '!!!!', 'non_ascii': 'éé',
}


@pytest.mark.asyncio
async def test_malformed_cursor_and_page_token_shapes_are_typed_refusals_and_valid_tokens_still_work(gateway):
    _kanban_env(gateway)
    _fill_board(gateway, 'tokens', 5)
    before = _db_fingerprint(gateway)
    async with native_socket(gateway.home, gateway.descriptor) as ws:
        first = await ws.result('kanban.board.snapshot', board='tokens', limit=2)
        valid_page_token, cursor = first['next_page_token'], (await _pages(ws, 'tokens', 500))[-1]['cursor']
        for name, token in MALFORMED_TOKENS.items():
            replay = await ws.result('kanban.events.since', board='tokens', cursor=token)
            page = await ws.result('kanban.board.snapshot', board='tokens', limit=2, page_token=token)
            assert (replay['state'], replay['events'], replay['reason']) == ('snapshot_required', [], 'invalid_cursor'), name
            assert (page['state'], page['reason']) == ('snapshot_required', 'invalid_cursor'), name
        crossed = await ws.result('kanban.events.since', board='tokens', cursor=valid_page_token)
        assert (crossed['state'], crossed['reason']) == ('snapshot_required', 'invalid_cursor')
        crossed = await ws.result('kanban.board.snapshot', board='tokens', limit=2, page_token=cursor)
        assert (crossed['state'], crossed['reason']) == ('snapshot_required', 'invalid_cursor')
        second = await ws.result('kanban.board.snapshot', board='tokens', limit=2, page_token=valid_page_token)
        assert second['state'] == 'present' and second == await ws.result('kanban.board.snapshot', board='tokens', limit=2, page_token=valid_page_token)
        assert (await ws.result('kanban.events.since', board='tokens', cursor=cursor))['state'] == 'ok'
        assert (await ws.result('kanban.board.snapshot', board='tokens', limit=2, page_token=encode_token(valid_page_token, gateway='f' * 32)))['reason'] == 'wrong_gateway'
    assert _db_fingerprint(gateway) == before


@pytest.mark.asyncio
async def test_policy_recorder_receipts_project_for_the_current_run_and_stay_history_after_a_new_run(gateway, monkeypatch):
    from hermes_cli import kanban_pr_acceptance_store as store
    from hermes_cli.kanban_external_claim import claim_external
    kb, kbc = _kanban_env(gateway)
    kb.create_board('accept', dispatch_mode='external')
    outcome = {'ok': False, 'classification': 'failure'}
    receipt = lambda: {**outcome, 'pr_url': 'https://github.com/acme/repo/pull/7', 'head_sha': 'a' * 40, 'checks': [],
                       'recovery': 'retry after CI is green', 'detail': 'GitHub double'}
    monkeypatch.setattr(store, 'collect_acceptance', lambda *a, **k: receipt())
    published = {'published_pr': 'https://github.com/acme/repo/pull/7'}

    async def ci(task):
        async with native_socket(gateway.home, gateway.descriptor) as ws:
            detail = (await ws.result('kanban.card.get', board='accept', task_id=task))['detail']
        return detail['proof_run_id'], detail['ci_acceptance'], detail['proof_history']
    with kbc.connect_closing(board='accept') as conn:
        task = kb.create_task(conn, title='ship', assignee=PROFILE, completion_contract='acme/repo', board='accept')
        run_1 = claim_external(conn, task, profile=PROFILE, session_id='s1', board='accept').current_run_id
        assert not kb.complete_task(conn, task, result='done', metadata=published, expected_run_id=run_1, actor_profile=PROFILE)
    proof_run, state, history = await ci(task)
    assert proof_run == run_1 and (state['classification'], state['run_id']) == ('failure', run_1) and history == []
    with kbc.connect_closing(board='accept') as conn:
        assert kb.reclaim_task(conn, task, reason='retry')
        run_2 = claim_external(conn, task, profile=PROFILE, session_id='s2', board='accept').current_run_id
    proof_run, state, history = await ci(task)
    assert proof_run == run_2 and state['state'] == 'unknown' and [(h['kind'], h['run_id']) for h in history] == [('pr_acceptance', run_1)]
    outcome.update(ok=True, classification='green')
    with kbc.connect_closing(board='accept') as conn:
        assert kb.complete_task(conn, task, result='done', metadata=published, expected_run_id=run_2, actor_profile=PROFILE)
    proof_run, state, history = await ci(task)
    assert (state['state'], state['classification'], state['run_id']) == ('accepted', 'green', run_2)
    assert [h['run_id'] for h in history] == [run_1]
