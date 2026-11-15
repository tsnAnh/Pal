"""``session.timeline``: a chat's display entries paged by what a client paints.

Failure cases this file pins:
- a page counts stored rows, so tool-heavy or hidden-row stretches yield short or empty pages;
- pages repeat or skip entries, or the walk ends before the first entry;
- hidden rows reach the wire: ``display_kind: hidden`` (user and assistant), ``[System:`` markers,
  model-only micro-compaction merges, compaction summaries, rewound rows;
- a tool result lands on another page than its call, or arrives without its tool name;
- a cursor skips or repeats entries after a new turn or a compaction, or silently restarts after a rewind;
- a repeat page read re-reads the whole lineage, or a new turn serves a stale cached page;
- two profiles with the same session id share a cached projection;
- ``session.resume`` cannot open a chat with the newest page in the same reply;
- a user turn with an inline image loses the image to an ``[image]`` placeholder in its text;
- a photo turn the gateway pre-analyzed for a text-only model shows the model-facing vision notes instead
  of the authored text, and loses the photo;
- a user who types the vision-note wording verbatim has it rewritten.
- a settled connection request loses its card on reopen because its result never reaches the wire.
- a reply the model stored as a bare silence marker (``NO_REPLY``) paints as a bubble, or a closing marker
  stays on a real reply, or prose that only mentions the marker is dropped.
"""
import json

import pytest

from tests.gateway.test_session_mutation_model_busy import _owner


def _call_ids(prefix, count):
    return [f'{prefix}{n}' for n in range(count)]


def _tool_calls(names_and_ids):
    return [{'id': call_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps({'n': call_id})}}
            for name, call_id in names_and_ids]


def _seed_plain(db, target, turns, start=0):
    expected = []
    for n in range(start, start + turns):
        db.append_message(target, 'user', f'Q{n}')
        db.append_message(target, 'assistant', f'A{n}')
        expected += [('user', f'Q{n}'), ('assistant', f'A{n}')]
    return expected


def _seed_tools(db, target, tag, calls):
    db.append_message(target, 'user', f'{tag} go')
    ids = _call_ids(f'{tag}-', calls)
    db.append_message(target, 'assistant', '', tool_calls=_tool_calls([('terminal', i) for i in ids]))
    for call_id in ids:
        db.append_message(target, 'tool', f'out {call_id}', tool_call_id=call_id, tool_name='terminal')
    db.append_message(target, 'assistant', f'{tag} done')
    return [('user', f'{tag} go'), ('assistant', f'{tag} done')]


def _seed_image(db, target):
    db.append_message(target, 'user', 'draw a cat')
    db.append_message(target, 'assistant', 'drawing', tool_calls=_tool_calls([('image_generate', 'img-1')]))
    db.append_message(target, 'tool', json.dumps({'success': True, 'image': '/tmp/cat.png'}),
                      tool_call_id='img-1', tool_name='image_generate')
    return [('user', 'draw a cat'), ('assistant', 'drawing')]


def _seed_hidden(db, target):
    db.append_message(target, 'user', 'scaffold for the model', display_kind='hidden')
    db.append_message(target, 'assistant', 'internal reply', display_kind='hidden')
    db.append_message(target, 'user', '[System: model switched to frozen]')
    db.append_message(target, 'assistant', 'merged reply', display_metadata={'model_only': True})
    db.append_message(target, 'user', 'visible after hidden')
    db.append_message(target, 'assistant', 'visible answer')
    return [('user', 'visible after hidden'), ('assistant', 'visible answer')]


def _rich(db, target):
    expected = _seed_plain(db, target, 12)
    expected += _seed_tools(db, target, 'heavy', 30)
    expected += _seed_hidden(db, target)
    expected += _seed_image(db, target)
    expected += _seed_tools(db, target, 'light', 3)
    expected += _seed_plain(db, target, 9, start=12)
    return expected


def _timeline(db, target, profile='owned'):
    from gateway.session_timeline import load_timeline
    return load_timeline(profile, db, target, None)


def _walk(db, target, limit, between=None, profile='owned'):
    from gateway.session_timeline import page
    pages = [page(_timeline(db, target, profile), None, limit)]
    if between is not None:
        between()
    while pages[-1]['older'] is not None:
        pages.append(page(_timeline(db, target, profile), pages[-1]['older'], limit))
    return pages


def _flat(pages):
    return [entry for result in reversed(pages) for entry in result['entries']]


def _shape(entries):
    return [(entry['role'], entry['text']) for entry in entries]


@pytest.fixture
def db(tmp_path):
    from hermes_state import SessionDB
    store = SessionDB(tmp_path / 'state.db')
    store.create_session('s1', source='tui')
    yield store
    store.close()


@pytest.mark.parametrize('limit', [1, 7, 40, 100])
def test_pages_concatenate_to_exactly_the_visible_entries(db, limit):
    expected = _rich(db, 's1')
    pages = _walk(db, 's1', limit)
    entries = _flat(pages)
    assert _shape(entries) == expected
    assert len({entry['id'] for entry in entries}) == len(entries)
    assert [len(result['entries']) for result in pages[:-1]] == [limit] * (len(pages) - 1)
    assert 1 <= len(pages[-1]['entries']) <= limit
    assert entries == list(_timeline(db, 's1').entries)


def test_a_tool_result_rides_with_its_call_and_carries_its_name(db):
    _rich(db, 's1')
    for limit in (1, 2, 3):
        entries = _flat(_walk(db, 's1', limit))
        heavy = next(entry for entry in entries if entry['text'] == 'heavy done')
        assert 'tools' not in heavy
        drawing = next(entry for entry in entries if entry['text'] == 'drawing')
        [tool] = drawing['tools']
        assert tool['name'] == 'image_generate' and tool['call_id'] == 'img-1'
        assert json.loads(tool['result']) == {'success': True, 'image': '/tmp/cat.png'}
        assert all(entry['role'] in {'user', 'assistant'} for entry in entries)


def test_a_tool_only_unit_paints_only_when_it_holds_a_rendered_tool(db):
    db.append_message('s1', 'user', 'make two')
    db.append_message('s1', 'assistant', '', tool_calls=_tool_calls([('terminal', 't1'), ('image_generate', 'g1')]))
    db.append_message('s1', 'tool', 'ok', tool_call_id='t1', tool_name='terminal')
    db.append_message('s1', 'tool', '{"success": true}', tool_call_id='g1', tool_name='image_generate')
    entries = list(_timeline(db, 's1').entries)
    assert _shape(entries) == [('user', 'make two'), ('assistant', '')]
    assert [tool['name'] for tool in entries[1]['tools']] == ['terminal', 'image_generate']
    assert 'result' not in entries[1]['tools'][0] and entries[1]['tools'][1]['result'] == '{"success": true}'


def test_a_settled_connection_request_keeps_its_result_so_the_card_survives_reopen(db, tmp_path):
    settled = json.dumps({'op_id': 'op-1', 'status': 'settled',
                          'targets': [{'name': 'fixture-tools', 'state': 'skipped'}]})
    db.append_message('s1', 'user', 'turn it on')
    db.append_message('s1', 'assistant', '', tool_calls=_tool_calls([('manage_connections', 'c1')]))
    db.append_message('s1', 'tool', settled, tool_call_id='c1', tool_name='manage_connections')
    db.append_message('s1', 'assistant', 'skipped')
    entries = list(_timeline(db, 's1', profile=str(tmp_path)).entries)
    [card] = [tool for entry in entries for tool in entry.get('tools', ()) if tool['name'] == 'manage_connections']
    assert card['call_id'] == 'c1' and json.loads(card['result']) == json.loads(settled)

@pytest.mark.parametrize('stored, shown', [
    ('NO_REPLY', None),
    ('[SILENT]', None),
    ('Paris.\n\nNO_REPLY', 'Paris.'),
    ('Reply NO_REPLY when there is nothing to add.', 'Reply NO_REPLY when there is nothing to add.'),
])
def test_a_stored_silence_marker_never_paints(db, tmp_path, stored, shown):
    db.append_message('s1', 'user', 'anything new?')
    db.append_message('s1', 'assistant', stored)
    entries = list(_timeline(db, 's1', profile=str(tmp_path)).entries)
    assert [entry['text'] for entry in entries if entry['role'] == 'assistant'] == ([shown] if shown else [])

def test_a_user_turn_with_an_inline_image_keeps_its_text_and_image(db):
    uri = 'data:image/jpeg;base64,/9j/4AAQSkZJRg=='
    db.append_message('s1', 'user', [{'type': 'text', 'text': 'What do you make of this screenshot?'},
                                     {'type': 'image_url', 'image_url': {'url': uri}}])
    entries = list(_timeline(db, 's1').entries)
    assert [entry['text'] for entry in entries] == [f'What do you make of this screenshot?\n{uri}']


_VISION_NOTE = ("[The user sent an image~ Here's what I can see:\nA field of pink flowers.]\n"
                "[If you need a closer look, use vision_analyze with image_url: /srv/media/photo one.jpg ~]")


@pytest.mark.parametrize('caption, shown', [
    ('What flowers are these?', 'What flowers are these?\n\n@image:`/srv/media/photo one.jpg`'),
    ('', '@image:`/srv/media/photo one.jpg`'),
])
def test_a_pre_analyzed_photo_turn_shows_the_authored_text_and_the_photo(db, caption, shown):
    stored = f'{_VISION_NOTE}\n\n{caption}' if caption else _VISION_NOTE
    db.append_message('s1', 'user', stored, display_metadata={'vision_notes': True})
    db.append_message('s1', 'assistant', 'Peonies.')
    assert _shape(_timeline(db, 's1', profile=f'vision-{bool(caption)}').entries) == [('user', shown), ('assistant', 'Peonies.')]


def test_typed_vision_note_wording_without_the_gateway_stamp_stays_verbatim(db):
    db.append_message('s1', 'user', _VISION_NOTE)
    assert _shape(_timeline(db, 's1', profile='typed-note').entries) == [('user', _VISION_NOTE)]


def test_pages_heavy_with_inline_images_stay_under_the_page_byte_budget(db):
    from gateway.session_timeline import PAGE_BYTES
    shot = 'data:image/png;base64,' + 'A' * (PAGE_BYTES // 3)
    expected = []
    for n in range(8):
        db.append_message('s1', 'user', [{'type': 'text', 'text': f'shot {n}'},
                                         {'type': 'image_url', 'image_url': {'url': shot}}])
        db.append_message('s1', 'assistant', f'seen {n}')
        expected += [f'shot {n}\n{shot}', f'seen {n}']
    pages = _walk(db, 's1', 40)
    assert len(pages) > 1
    assert all(pages_entries and len(json.dumps(pages_entries)) <= PAGE_BYTES
               for pages_entries in (result['entries'] for result in pages))
    assert [entry['text'] for entry in _flat(pages)] == expected


def test_one_entry_larger_than_the_budget_still_pages_alone(db):
    from gateway.session_timeline import PAGE_BYTES
    huge = 'data:image/png;base64,' + 'B' * (PAGE_BYTES + 10)
    db.append_message('s1', 'user', [{'type': 'text', 'text': 'big'},
                                     {'type': 'image_url', 'image_url': {'url': huge}}])
    db.append_message('s1', 'assistant', 'ok')
    pages = _walk(db, 's1', 40)
    assert [len(result['entries']) for result in pages] == [1, 1]
    assert [entry['text'] for entry in _flat(pages)] == [f'big\n{huge}', 'ok']


def test_entry_ids_are_the_stored_message_uids(db):
    _seed_plain(db, 's1', 3)
    uids = [row['message_uid'] for row in db.get_messages_as_conversation('s1')]
    assert [entry['id'] for entry in _timeline(db, 's1').entries] == uids


def test_a_cursor_survives_a_new_turn_between_pages(db):
    expected = _rich(db, 's1')
    pages = _walk(db, 's1', 5, between=lambda: _seed_plain(db, 's1', 2, start=100))
    assert _shape(_flat(pages)) == expected


def test_a_cursor_survives_a_compaction_between_pages(db):
    from agent.context_compressor import SUMMARY_PREFIX
    expected = _seed_plain(db, 's1', 10)

    def compact():
        tail = db.get_messages_as_conversation('s1')[-4:]
        db.archive_and_compact('s1', [{'role': 'user', 'content': f'{SUMMARY_PREFIX}\n## Goal\nship'}, *tail],
                               watermark=db.get_active_message_watermark('s1'), tail_count=len(tail))
    pages = _walk(db, 's1', 3, between=compact)
    assert _shape(_flat(pages)) == expected
    assert _shape(_timeline(db, 's1').entries) == expected


def test_a_compacted_rotated_lineage_pages_whole_without_summaries(tmp_path):
    from agent.context_compressor import SUMMARY_PREFIX
    from hermes_state import SessionDB
    db = SessionDB(tmp_path / 'rotated.db')
    db.create_session('root', source='tui', model='m')
    expected = _seed_plain(db, 'root', 6)
    assert db.try_acquire_compression_lock('root', 'fixture')
    try:
        db.publish_compression_child(parent_session_id='root', child_session_id='tip', source='tui', model='m',
            messages=[{'role': 'user', 'content': f'{SUMMARY_PREFIX}\n## Goal\nship it'},
                      {'role': 'user', 'content': 'after rotation'},
                      {'role': 'assistant', 'content': 'rotated answer'}],
            compression_lock_holder='fixture')
    finally:
        db.release_compression_lock('root', 'fixture')
    expected += [('user', 'after rotation'), ('assistant', 'rotated answer')]
    assert _shape(_flat(_walk(db, 'tip', 4))) == expected
    archived = [entry['text'] for entry in _timeline(db, 'tip').entries if entry.get('archived')]
    assert archived == [text for _, text in expected[:12]]
    db.close()


def test_a_rewound_cursor_is_stale_and_the_rest_pages_clean(db):
    from gateway.session_timeline import page
    from hermes_state_runtime import RuntimeStoreError
    _seed_plain(db, 's1', 10)
    first = page(_timeline(db, 's1'), None, 4)
    newest_user = next(entry for entry in first['entries'] if entry['role'] == 'user')
    db.rewind_to_message('s1', newest_user['row_id'])
    with pytest.raises(RuntimeStoreError) as refused:
        page(_timeline(db, 's1'), first['older'], 4)
    assert refused.value.reason == 'cursor_stale'
    pages = _walk(db, 's1', 4)
    assert _shape(_flat(pages)) == _seed_expected(8)


def _seed_expected(turns):
    return [pair for n in range(turns) for pair in (('user', f'Q{n}'), ('assistant', f'A{n}'))]


def test_a_cursor_of_another_session_or_garbage_is_refused(db):
    from gateway.session_timeline import page
    from hermes_state_runtime import RuntimeStoreError
    _seed_plain(db, 's1', 3)
    for cursor, reason in (('tl1.' + 'Zm9yZWlnbg', 'cursor_stale'), ('nope', 'invalid_params'),
                           ('tl1.!!', 'invalid_params')):
        with pytest.raises(RuntimeStoreError) as refused:
            page(_timeline(db, 's1'), cursor, 2)
        assert refused.value.reason == reason


def test_a_repeat_page_reads_no_lineage_and_a_new_turn_invalidates(db, monkeypatch):
    from gateway.session_timeline import page
    _rich(db, 's1')
    reads = []
    real = db.get_messages_as_conversation

    def counting(*args, **kwargs):
        reads.append(kwargs.get('include_ancestors', False))
        return real(*args, **kwargs)
    monkeypatch.setattr(db, 'get_messages_as_conversation', counting)
    first = page(_timeline(db, 's1'), None, 10)
    cold = len(reads)
    assert cold >= 1
    second = page(_timeline(db, 's1'), first['older'], 10)
    assert len(reads) == cold and second['revision'] == first['revision']
    db.append_message('s1', 'user', 'fresh question')
    fresh = page(_timeline(db, 's1'), None, 1)
    assert len(reads) > cold and fresh['revision'] != first['revision']
    assert _shape(fresh['entries']) == [('user', 'fresh question')]


def test_profiles_with_the_same_session_id_never_share_a_projection(tmp_path):
    from hermes_state import SessionDB
    stores = {}
    for profile in ('alpha', 'beta'):
        (tmp_path / profile).mkdir()
        stores[profile] = SessionDB(tmp_path / profile / 'state.db')
        stores[profile].create_session('s1', source='tui')
        stores[profile].append_message('s1', 'user', f'{profile} question')
    for profile, store in stores.items():
        assert _shape(_timeline(store, 's1', profile=str(tmp_path / profile)).entries) == [('user', f'{profile} question')]
        store.close()


@pytest.mark.asyncio
async def test_rpc_pages_resume_carries_the_newest_page_and_capability_is_advertised(tmp_path, monkeypatch):
    from gateway.session_controls import AuthorityConnection
    from gateway.session_local_recovery import transcript_target

    async def handle(event):
        return 'ok'
    store, db, authority, owner, ref = _owner(tmp_path, monkeypatch, handle)

    async def call(connection, method, **params):
        return await connection.dispatch({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    try:
        target = transcript_target(authority, ref)
        expected = _rich(db, target)
        described = await call(owner, 'runtime.describe')
        assert 'session-timeline-v1' in described['result']['capabilities']
        assert 'session-history-page-v1' not in described['result']['capabilities']
        resumed = (await call(owner, 'session.resume', session_id=ref.session_id, omit_messages=True,
                              timeline_limit=6))['result']
        pages = [resumed['timeline']]
        while pages[-1]['older'] is not None:
            reply = await call(owner, 'session.timeline', session_id=ref.session_id, before=pages[-1]['older'],
                               limit=6)
            assert 'result' in reply, reply
            pages.append(reply['result'])
        assert _shape(_flat(pages)) == expected
        latest = (await call(owner, 'session.timeline', session_id=ref.session_id))['result']
        assert len(latest['entries']) == 40 and latest['entries'][-1]['text'] == 'A20'
        for params in ({'limit': 0}, {'limit': 101}, {'before': 7}, {'message_limit': 5}):
            refused = await call(owner, 'session.timeline', session_id=ref.session_id, **params)
            assert refused['error']['data']['reason'] == 'invalid_params', refused
        refused = await call(owner, 'session.resume', session_id=ref.session_id, message_limit=5)
        assert refused['error']['data']['reason'] == 'invalid_params', refused
        stale = await call(owner, 'session.timeline', session_id=ref.session_id, before='tl1.Z29uZQ')
        assert stale['error']['data']['reason'] == 'cursor_stale', stale
        other = AuthorityConnection(authority, object(), {'user_id': 'someone-else'})
        refused = await call(other, 'session.timeline', session_id=ref.session_id)
        assert refused['error']['data']['reason'] == 'permission_denied', refused
        await other.close()
    finally:
        await owner.close()
        store.close_all_db_handles()
