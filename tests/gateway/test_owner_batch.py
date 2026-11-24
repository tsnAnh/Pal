import asyncio

import pytest

from gateway import send_stats, session_finite
from gateway.platforms.base import get_image_cache_dir
from gateway.session_queued_controls import steer_blocker
from tests.gateway.test_owner_absorb import (
    RunningAgent, Turn, _drained, _owner_connection, _submit_as_owner, bot_chat, db_admissions,
)
from tests.gateway.test_prompt_queued_controls import _call, _ledger, interactive
from tests.waiting import async_wait_until

__all__ = ['bot_chat']

PAL_SEND = {'clarify_batch': True}


async def _pal_send(conn, request_id, text=None, **extra):
    reply = await _call(conn, 'prompt.submit', submission_id=request_id, text=text or request_id, **PAL_SEND, **extra)
    assert 'error' not in reply, reply
    return reply['result']


def _trace(caplog):
    return [record.getMessage() for record in caplog.records if record.name == 'gateway.send_trace']


@pytest.mark.asyncio
async def test_the_pal_apps_send_is_steered_not_queued(bot_chat, monkeypatch, caplog):
    db, authority = bot_chat
    interactive(db, source='ios')
    turn = Turn(monkeypatch, drain=True)
    caplog.set_level('WARNING')
    with db:
        conn = _owner_connection(authority)
        assert (await _pal_send(conn, 'running'))['status'] == 'turn'
        await asyncio.wait_for(turn.claimed.wait(), 30)
        second = await _pal_send(conn, 'also check the weather')
        committed = db_admissions(db, ['also check the weather'])[0].payload
        assert committed['cli_turn_v1'] == {'clarify_batch': True}
        assert second['status'] == 'steered', second
        turn.release.set()
        await _drained(authority)
    assert turn.taken == ['also check the weather'] and turn.ran == ['running']
    assert any('status=steered why=absorbed' in line for line in _trace(caplog)), _trace(caplog)


@pytest.mark.asyncio
async def test_five_messages_during_one_turn_reach_it_in_order_and_start_no_other_turn(bot_chat, monkeypatch, caplog):
    db, authority = bot_chat
    interactive(db, source='ios')
    turn = Turn(monkeypatch, drain=True)
    caplog.set_level('WARNING')
    names = ['one', 'two', 'three', 'four', 'five']
    with db:
        conn = _owner_connection(authority)
        await _pal_send(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        statuses = [(await _pal_send(conn, name))['status'] for name in names]
        turn.release.set()
        await _drained(authority)
    assert statuses == ['steered'] * 5
    assert turn.ran == ['running'] and turn.taken == ['one\ntwo\nthree\nfour\nfive']
    assert _ledger(authority.persistence) == [('running', 'terminal', 'completed'),
                                              *[(name, 'terminal', 'steered') for name in names]]
    assert sum('status=steered why=absorbed' in line for line in _trace(caplog)) == 5
    assert not any('status=queued' in line for line in _trace(caplog))
    assert send_stats.summary(hours=1)['by_status']['queued'] == 0


@pytest.mark.asyncio
async def test_messages_sent_while_the_turn_builds_its_agent_go_in_when_it_adopts_one(bot_chat, monkeypatch):
    db, authority = bot_chat
    agent, claimed, adopt, release, taken, ran = RunningAgent(), asyncio.Event(), asyncio.Event(), asyncio.Event(), [], []

    async def execute(owner, ref, row):
        ran.append(row['payload']['text'])
        claimed.set()
        await asyncio.wait_for(adopt.wait(), 30)
        owner.adopt_agent(ref.session_id, row['generation'], agent)
        await asyncio.wait_for(release.wait(), 30)
        taken.append(agent._drain_pending_steer())
        return 'done'
    monkeypatch.setattr(session_finite, 'execute_finite_admission', execute)
    with db:
        conn = _owner_connection(authority)
        await _pal_send(conn, 'running')
        await asyncio.wait_for(claimed.wait(), 30)
        assert [(await _pal_send(conn, name))['status'] for name in ('early', 'earlier')] == ['steered', 'steered']
        receipt = await _call(conn, 'prompt.receipt', admission_id=db_admissions(db, ['early'])[0].admission_id)
        assert (receipt['result']['status'], receipt['result']['outcome']) == ('started', None)
        adopt.set()
        await async_wait_until(lambda: agent._pending_steer == 'early\nearlier', timeout=30, what='the latched text')
        release.set()
        await _drained(authority)
    assert ran == ['running'] and taken == ['early\nearlier']
    assert _ledger(authority.persistence) == [('running', 'terminal', 'completed'), ('early', 'terminal', 'steered'),
                                              ('earlier', 'terminal', 'steered')]


class EndingTurn:
    def __init__(self, monkeypatch, outcome):
        self.agent, self.claimed, self.release, self.ran = RunningAgent(), asyncio.Event(), asyncio.Event(), []

        async def execute(owner, ref, row):
            self.ran.append(row['payload']['text'])
            owner.adopt_agent(ref.session_id, row['generation'], self.agent)
            if len(self.ran) == 1:
                self.claimed.set()
                await asyncio.wait_for(self.release.wait(), 30)
                if outcome == 'fails':
                    raise RuntimeError('provider down')
            return 'done'
        monkeypatch.setattr(session_finite, 'execute_finite_admission', execute)


@pytest.mark.asyncio
@pytest.mark.parametrize('outcome', ['ends', 'fails'])
async def test_what_the_turn_never_drained_runs_as_one_follow_up_input_in_order(bot_chat, monkeypatch, outcome):
    db, authority = bot_chat
    turn = EndingTurn(monkeypatch, outcome)
    names = ['one', 'two', 'three', 'four', 'five']
    with db:
        conn = _owner_connection(authority)
        await _pal_send(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        assert [(await _pal_send(conn, name))['status'] for name in names] == ['steered'] * 5
        turn.release.set()
        await async_wait_until(lambda: len(turn.ran) == 2, timeout=30, what='the one follow-up turn')
        await _drained(authority)
        retry = await _pal_send(conn, 'two')
    assert turn.ran == ['running', 'one\ntwo\nthree\nfour\nfive'], 'one follow-up turn, in order, none dropped'
    assert retry['status'] == 'steered' and len(turn.ran) == 2, 'a retried send never runs twice'
    assert _ledger(authority.persistence) == [
        ('running', 'terminal', 'completed' if outcome == 'ends' else 'failed'),
        ('one', 'terminal', 'completed'),
        *[(name, 'terminal', 'steered') for name in names[1:]]]


@pytest.mark.asyncio
async def test_an_attachment_keeps_its_place_and_the_messages_behind_it_join_its_one_turn(bot_chat, monkeypatch, caplog):
    db, authority = bot_chat
    turn = Turn(monkeypatch, drain=True)
    caplog.set_level('WARNING')
    picture = get_image_cache_dir() / 'batch.png'
    picture.write_bytes(b'\x89PNG\r\n\x1a\nbatch')
    seen = []
    original = session_finite.execute_finite_admission

    async def execute(owner, ref, row):
        seen.append(row['payload'].get('attachments_v1', {}).get('media_types'))
        return await original(owner, ref, row)
    monkeypatch.setattr(session_finite, 'execute_finite_admission', execute)
    with db:
        conn = _owner_connection(authority)
        await _pal_send(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        assert (await _pal_send(conn, 'first'))['status'] == 'steered'
        with_picture = await _pal_send(conn, 'look', attachments=[{'path': str(picture), 'mime': 'image/png'}])
        after = [(await _pal_send(conn, name))['status'] for name in ('after one', 'after two')]
        assert (with_picture['status'], after) == ('queued', ['queued', 'queued'])
        turn.release.set()
        await async_wait_until(lambda: len(turn.ran) == 2, timeout=30, what='the one follow-up turn')
        await _drained(authority)
    assert turn.ran == ['running', 'look\nafter one\nafter two'] and turn.taken == ['first', None]
    assert seen == [None, ['image/png']]
    reasons = [line for line in _trace(caplog) if 'status=queued' in line]
    assert any('why=not_steerable:payload_keys:attachments_v1' in line for line in reasons), reasons
    assert any('why=behind_queue' in line for line in reasons), reasons
    assert _ledger(authority.persistence) == [
        ('running', 'terminal', 'completed'), ('first', 'terminal', 'steered'), ('look', 'terminal', 'completed'),
        ('after one', 'terminal', 'steered'), ('after two', 'terminal', 'steered')]


@pytest.mark.asyncio
async def test_a_queued_message_is_still_cancellable_until_it_is_handed_to_a_turn(bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch, drain=True)
    with db:
        conn = _owner_connection(authority)
        await _pal_send(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        await _call(conn, 'prompt.submit', submission_id='whole turn', text='whole turn', finite=True)
        gone = await _pal_send(conn, 'withdrawn', finite=True)
        cancelled = await _call(conn, 'prompt.cancel', admission_id=gone['admission_id'])
        assert 'error' not in cancelled, cancelled
        turn.release.set()
        await async_wait_until(lambda: turn.ran == ['running', 'whole turn'], timeout=30, what='the queue to advance')
        await _drained(authority)
    assert _ledger(authority.persistence)[-1] == ('withdrawn', 'terminal', 'cancelled')


@pytest.mark.asyncio
async def test_a_send_while_idle_starts_its_own_turn(bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch)
    with db:
        conn = _owner_connection(authority)
        assert (await _pal_send(conn, 'running'))['status'] == 'turn'
        await asyncio.wait_for(turn.claimed.wait(), 30)
        turn.release.set()
        await _drained(authority)
    assert turn.ran == ['running']


def test_the_send_trace_names_the_payload_keys_that_keep_a_message_queued_and_never_its_text(bot_chat):
    db, authority = bot_chat
    row = {'status': 'queued', 'target_session_id': 's',
           'payload': {'text': 'SENTINEL', 'finite': True, 'cli_turn_v1': {'clarify_batch': True, 'api_text': 'SENTINEL'}}}
    with db:
        blocker = steer_blocker(authority, row, any_source=True)
        assert blocker == 'payload_keys:cli_turn_v1.api_text,finite'
        assert 'SENTINEL' not in blocker
        assert steer_blocker(authority, {**row, 'payload': {'text': 'hi', 'cli_turn_v1': {'clarify_batch': True}}}) is None
        assert steer_blocker(authority, {**row, 'payload': {'text': ' '}}) == 'empty'
        assert steer_blocker(authority, {**row, 'payload': {'text': 'hi', 'display_v1': {'kind': 'hidden'}}}) == 'hidden'
        interactive(db, source='bot_room')
        authority.launch_sources.clear()
        assert steer_blocker(authority, {**row, 'payload': {'text': 'hi'}}) == 'source'
        assert steer_blocker(authority, {**row, 'payload': {'text': 'hi'}}, any_source=True) is None
