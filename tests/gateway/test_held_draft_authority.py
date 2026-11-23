import asyncio
import json
import textwrap
import threading
from types import SimpleNamespace

import pytest

import hermes_cli.config as hermes_config
from gateway.session_controls import AuthorityConnection
from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner
from tools import bot_mode_draft_store
from tools.bot_mode_drafts import classify_outbound

EMAIL = 'connectors__gmail__SEND_EMAIL'
ARGS = {'to': 'ada@example.com', 'subject': 'Lunch', 'body': 'Lunch at noon?'}
pytestmark = pytest.mark.usefixtures('authority_cwd_in_tmp')
MANAGED = textwrap.dedent("""\
    ui_meta:
      hermes-bots:
        shape: cloud
""")


def _hold(home):
    return bot_mode_draft_store.hold(classify_outbound(EMAIL, ARGS), ARGS, origin='unattended', home=home)


async def _rpc(connection, method, **params):
    return await connection.dispatch({'id': method, 'method': method, 'params': params})


async def _chat(connection, authority, tmp_path, name):
    live, _ = await _create(connection, authority, name, tmp_path, source='ios')
    return next(sid for sid, candidate in authority.sessions.items() if candidate is live)


def _answer(connection, sid, draft, choice, **extra):
    return _rpc(connection, 'approval.respond', session_id=sid, prompt_id=f"draft:{draft['id']}", choice=choice, **extra)


@pytest.fixture
def sends(monkeypatch):
    calls = []

    def deliver(tool, args, **kwargs):
        calls.append((tool, dict(args)))
        return json.dumps({'response': 'ok'})

    monkeypatch.setattr('model_tools.handle_function_call', deliver)
    return calls


@pytest.fixture
def managed(tmp_path, monkeypatch):
    home = tmp_path / 'home'
    home.mkdir()
    (home / 'profile.yaml').write_text(MANAGED, encoding='utf-8')
    hermes_config._LOAD_CONFIG_CACHE.clear()
    store, _runner, authority, connection = _owner(home, monkeypatch, {'model': {'default': 'm'}})
    yield SimpleNamespace(tmp=tmp_path, home=home, authority=authority, connection=connection)
    hermes_config._LOAD_CONFIG_CACHE.clear()
    store.close_all_db_handles()


@pytest.mark.asyncio
async def test_any_chat_of_a_managed_profile_lists_its_held_drafts(managed):
    first = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    second = await _chat(managed.connection, managed.authority, managed.tmp, 'two')
    record = _hold(managed.home)
    for sid in (first, second):
        (card,) = (await _rpc(managed.connection, 'approval.pending', session_id=sid))['result']['approvals']
        assert card['request_id'] == f"draft:{record['id']}"
        assert card['draft']['text'] == 'Lunch at noon?'
        assert card['draft']['state'] == 'pending' and card['draft']['held'] is True


@pytest.mark.asyncio
async def test_a_profile_that_is_not_bot_managed_lists_and_answers_no_drafts(tmp_path, monkeypatch, sends):
    home = tmp_path / 'plain'
    store, _runner, authority, connection = _owner(home, monkeypatch, {'model': {'default': 'm'}})
    try:
        sid = await _chat(connection, authority, tmp_path, 'one')
        record = _hold(home)
        assert (await _rpc(connection, 'approval.pending', session_id=sid))['result'] == {'approvals': []}
        refused = await _answer(connection, sid, record, 'once')
        assert refused['error']['data'].items() >= {'reason': 'not_found', 'state': None}.items()
        assert sends == [] and len(bot_mode_draft_store.list_pending(home)) == 1
    finally:
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_approve_sends_once_and_a_second_approval_is_refused_with_the_true_state(managed, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    other = await _chat(managed.connection, managed.authority, managed.tmp, 'two')
    record = _hold(managed.home)
    reply = await _answer(managed.connection, sid, record, 'once')
    assert reply['result'] == {'status': 'resolved', 'prompt_id': f"draft:{record['id']}", 'state': 'sent'}
    assert sends == [(EMAIL, ARGS)]
    again = await _answer(managed.connection, other, record, 'once')
    assert again['error']['code'] == 4134
    assert again['error']['data'].items() >= {'reason': 'already_sent', 'state': 'sent'}.items()
    cancel = await _answer(managed.connection, sid, record, 'deny')
    assert cancel['error']['data'].items() >= {'reason': 'already_sent', 'state': 'sent'}.items()
    assert len(sends) == 1
    assert (await _rpc(managed.connection, 'approval.pending', session_id=sid))['result'] == {'approvals': []}


@pytest.mark.asyncio
async def test_concurrent_approvals_from_two_chats_send_once(managed, monkeypatch):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    other = await _chat(managed.connection, managed.authority, managed.tmp, 'two')
    record = _hold(managed.home)
    sent, entered, release = [], threading.Event(), threading.Event()

    def slow_send(tool, args, **kwargs):
        sent.append(args)
        entered.set()
        release.wait(10)
        return json.dumps({'response': 'ok'})

    monkeypatch.setattr('model_tools.handle_function_call', slow_send)
    first = asyncio.ensure_future(_answer(managed.connection, sid, record, 'once'))
    assert await asyncio.to_thread(entered.wait, 10)
    racing = await _answer(managed.connection, other, record, 'once')
    release.set()
    reply = await first
    assert reply['result']['state'] == 'sent'
    assert racing['error']['data']['reason'] == 'in_progress' and racing['error']['data']['state'] == 'approved'
    assert len(sent) == 1


@pytest.mark.asyncio
async def test_cancel_never_sends_and_is_final(managed, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    record = _hold(managed.home)
    reply = await _answer(managed.connection, sid, record, 'deny')
    assert reply['result'] == {'status': 'resolved', 'prompt_id': f"draft:{record['id']}", 'state': 'cancelled'}
    later = await _answer(managed.connection, sid, record, 'once')
    assert later['error']['data'].items() >= {'reason': 'already_cancelled', 'state': 'cancelled'}.items()
    assert sends == []
    assert (await _rpc(managed.connection, 'approval.pending', session_id=sid))['result'] == {'approvals': []}


@pytest.mark.asyncio
async def test_a_failed_send_reports_the_reason_and_the_draft_stays_pending_as_failed(managed, monkeypatch):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    record = _hold(managed.home)
    monkeypatch.setattr('model_tools.handle_function_call',
                        lambda tool, args, **kw: json.dumps({'error': 'mailbox quota exceeded'}))
    reply = await _answer(managed.connection, sid, record, 'once')
    assert reply['error']['code'] == 4134
    assert reply['error']['data'].items() >= {'reason': 'send_failed', 'state': 'failed'}.items()
    assert 'mailbox quota exceeded' in reply['error']['message'] and 'NOT sent' in reply['error']['message']
    (card,) = (await _rpc(managed.connection, 'approval.pending', session_id=sid))['result']['approvals']
    assert card['draft']['state'] == 'failed' and 'mailbox quota exceeded' in card['draft']['error']
    sent = []
    monkeypatch.setattr('model_tools.handle_function_call',
                        lambda tool, args, **kw: sent.append(args) or json.dumps({'response': 'ok'}))
    retry = await _answer(managed.connection, sid, record, 'once')
    assert retry['result']['state'] == 'sent' and len(sent) == 1


@pytest.mark.asyncio
async def test_edit_then_approve_sends_the_edited_text(managed, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    record = _hold(managed.home)
    reply = await _answer(managed.connection, sid, record, 'once', edited_text='Lunch at one?')
    assert reply['result']['state'] == 'sent'
    assert sends == [(EMAIL, {**ARGS, 'body': 'Lunch at one?'})]


@pytest.mark.asyncio
async def test_an_edit_only_goes_with_approval(managed, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    record = _hold(managed.home)
    reply = await _answer(managed.connection, sid, record, 'deny', edited_text='nope')
    assert reply['error']['data']['reason'] == 'invalid_params'
    assert sends == [] and len(bot_mode_draft_store.list_pending(managed.home)) == 1


@pytest.mark.asyncio
async def test_a_draft_of_another_profile_is_not_found(managed, tmp_path, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    foreign = tmp_path / 'foreign'
    foreign.mkdir()
    record = _hold(foreign)
    reply = await _answer(managed.connection, sid, record, 'once')
    assert reply['error']['data'].items() >= {'reason': 'not_found', 'state': None}.items()
    assert sends == [] and len(bot_mode_draft_store.list_pending(foreign)) == 1


@pytest.mark.asyncio
async def test_a_viewer_without_approve_or_not_attached_cannot_answer(managed, sends):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    record = _hold(managed.home)
    reader = AuthorityConnection(managed.authority, object(), {
        'user_id': 'human', 'capabilities': ['session:read', 'session:submit']})
    try:
        attached = await _rpc(reader, 'session.resume', session_id=sid)
        assert 'result' in attached, attached
        refused = await _answer(reader, sid, record, 'once')
        assert refused['error']['data']['reason'] == 'permission_denied'
        stranger = AuthorityConnection(managed.authority, object(), {'user_id': 'human'})
        try:
            refused = await _answer(stranger, sid, record, 'once')
            assert refused['error']['data']['reason'] == 'permission_denied'
        finally:
            await stranger.close()
    finally:
        await reader.close()
    assert sends == [] and len(bot_mode_draft_store.list_pending(managed.home)) == 1


@pytest.mark.asyncio
async def test_a_live_prompt_still_needs_its_generation(managed):
    sid = await _chat(managed.connection, managed.authority, managed.tmp, 'one')
    reply = await _rpc(managed.connection, 'approval.respond', session_id=sid, prompt_id='live-1', choice='once')
    assert reply['error']['data']['reason'] == 'invalid_params'
