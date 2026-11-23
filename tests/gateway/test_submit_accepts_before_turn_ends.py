"""``prompt.submit`` accepts: the receipt returns while the bot's turn is still running, a second message is
admitted and persisted at once behind it, and a replay of one submission id is one admission."""
import asyncio

import pytest

from tests.gateway.test_owner_absorb import Turn
from tests.gateway.test_prompt_queued_controls import _call, _connection, _ledger, interactive
from tests.gateway.test_session_authority_cancel_settlement import _authority

ACCEPT_WITHIN_SECONDS = 5


async def _submit(conn, request_id, text=None):
    return await asyncio.wait_for(_call(conn, 'prompt.submit', submission_id=request_id, text=text or request_id),
                                  ACCEPT_WITHIN_SECONDS)


@pytest.fixture
def running_turn(tmp_path, monkeypatch):
    db, authority = _authority(tmp_path, monkeypatch)
    interactive(authority.persistence)
    return db, authority, Turn(monkeypatch)


async def _finish(authority, turn):
    turn.release.set()
    await asyncio.wait_for(authority.sessions['s'].task, 30)


@pytest.mark.asyncio
async def test_the_receipt_returns_while_the_turn_is_still_running(running_turn):
    db, authority, turn = running_turn
    with db:
        conn = _connection(authority)
        first = await _submit(conn, 'long task')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        assert not turn.release.is_set() and not authority.sessions['s'].task.done()
        assert first['result']['status'] in ('queued', 'started'), first
        running = await _call(conn, 'prompt.receipt', admission_id=first['result']['admission_id'])
        assert running['result']['status'] == 'started'
        await _finish(authority, turn)
    assert turn.ran == ['long task']


@pytest.mark.asyncio
async def test_a_message_sent_while_the_turn_runs_is_admitted_and_persisted_at_once(running_turn):
    db, authority, turn = running_turn
    with db:
        conn = _connection(authority)
        await _submit(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        second = await _submit(conn, 'follow-up')
        assert 'error' not in second, second
        assert (second['result']['status'], second['result']['outcome']) == ('queued', None)
        assert not turn.release.is_set()
        assert _ledger(authority.persistence) == [('running', 'started', None), ('follow-up', 'queued', None)]
        queued = await _call(conn, 'prompt.receipt', admission_id=second['result']['admission_id'])
        assert queued['result']['status'] == 'queued'
        await _finish(authority, turn)
    assert turn.ran == ['running', 'follow-up']


@pytest.mark.asyncio
async def test_the_same_submission_id_is_one_admission_and_one_receipt(running_turn):
    db, authority, turn = running_turn
    with db:
        conn = _connection(authority)
        await _submit(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        first = await _submit(conn, 'follow-up')
        replay = await _submit(conn, 'follow-up')
        assert replay['result'] == first['result']
        assert [row for row in _ledger(authority.persistence) if row[0] == 'follow-up'] == [
            ('follow-up', 'queued', None)]
        await _finish(authority, turn)
    assert turn.ran.count('follow-up') == 1


@pytest.mark.asyncio
async def test_a_draining_gateway_refuses_by_name_instead_of_holding_the_submit(running_turn):
    db, authority, _turn = running_turn
    with db:
        conn = _connection(authority)
        authority.runner._draining = True
        refused = await _submit(conn, 'during restart')
        assert refused['error']['data']['reason'] == 'runtime_draining', refused
        assert _ledger(authority.persistence) == []
        authority.runner._draining = False
