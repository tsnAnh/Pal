"""The owner's ``prompt.submit`` into a Bot Chat whose turn is running is absorbed into that turn: committed
as a durable admission, transferred through the steer fence, and reported ``steered``. Everything else
(other sessions, bot DMs, operators, a turn still building its agent) keeps its FIFO place."""
import asyncio
import threading

import pytest

from agent.interrupt_control import InterruptControlMixin, _steer_parts
from gateway import session_finite
from gateway.session_contract import SessionActor, Submission
from tests.gateway.test_prompt_queued_controls import _call, _connection, _ledger, interactive
from tests.gateway.test_session_authority_cancel_settlement import ACTOR, REF, _authority
from tests.waiting import async_wait_until
from tools import interrupt as interrupt_mod


class RunningAgent(InterruptControlMixin):
    """The real steer/absorb seam over a turn that is executing a tool on worker thread 4242."""

    api_mode = "chat_completions"
    WORKER = 4242

    def __init__(self):
        self._pending_steer, self._pending_steer_lock = None, threading.Lock()
        self._pending_redirect, self._pending_redirect_lock = None, threading.Lock()
        self._executing_tools = True
        self._tool_worker_threads, self._tool_worker_threads_lock = {self.WORKER}, threading.Lock()

    def clear_interrupt(self, *args, **kwargs):
        return True


class Turn:
    def __init__(self, monkeypatch, *, adopt=True, drain=False):
        self.agent, self.claimed, self.release = RunningAgent(), asyncio.Event(), asyncio.Event()
        self.ran, self.taken = [], []

        async def execute(authority, ref, row):
            self.ran.append(row['payload']['text'])
            if adopt:
                authority.adopt_agent(ref.session_id, row['generation'], self.agent)
            self.claimed.set()
            await asyncio.wait_for(self.release.wait(), 30)
            if drain:
                self.taken.append(self.agent._drain_pending_steer())
            return 'done'
        monkeypatch.setattr(session_finite, 'execute_finite_admission', execute)


@pytest.fixture
def bot_chat(tmp_path, monkeypatch):
    db, authority = _authority(tmp_path, monkeypatch)
    interactive(db)
    (tmp_path / 'profiles' / 'chief').mkdir(parents=True)
    (tmp_path / 'profiles' / 'chief' / 'profile.yaml').write_text('ui_meta:\n  hermes-bots:\n    title: Chief\n')
    db.set_session_title('s', 'Bot Chat')
    yield db, authority
    interrupt_mod.take_yield(RunningAgent.WORKER)


def _owner_connection(authority):
    conn = _connection(authority)
    authority.sessions['s'].source.user_id = conn.actor.subject
    return conn


async def _drained(authority):
    task = authority.sessions['s'].task
    if task is not None:
        await asyncio.wait_for(task, 30)


async def _submit_as_owner(conn, request_id, text=None):
    reply = await _call(conn, 'prompt.submit', submission_id=request_id, text=text or request_id)
    assert 'error' not in reply, reply
    return reply['result']


@pytest.mark.asyncio
async def test_an_owner_message_during_a_bot_chat_turn_is_steered_in_and_every_tool_is_asked_to_yield(
        bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch, drain=True)
    with db:
        conn = _owner_connection(authority)
        first = await _submit_as_owner(conn, 'running')
        assert first['status'] == 'turn'
        await asyncio.wait_for(turn.claimed.wait(), 30)

        second = await _submit_as_owner(conn, 'also check the weather')
        assert second['status'] == 'steered', second
        assert turn.agent._pending_steer == 'also check the weather'
        assert interrupt_mod.take_yield(RunningAgent.WORKER) is interrupt_mod.YieldReason.OWNER_MESSAGE
        receipt = await _call(conn, 'prompt.receipt', admission_id=second['admission_id'])
        assert (receipt['result']['status'], receipt['result']['outcome']) == ('started', None)

        turn.release.set()
        await _drained(authority)
    assert turn.taken == ['also check the weather'] and turn.ran == ['running']
    assert _ledger(db) == [('running', 'terminal', 'completed'), ('also check the weather', 'terminal', 'steered')]


@pytest.mark.asyncio
async def test_two_owner_messages_before_one_drain_each_hold_their_own_ticket(bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch, drain=True)
    with db:
        conn = _owner_connection(authority)
        await _submit_as_owner(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        statuses = [(await _submit_as_owner(conn, name))['status'] for name in ('a', 'b')]
        assert statuses == ['steered', 'steered']
        assert [ticket for ticket, _ in _steer_parts(turn.agent) if ticket] == [
            row['admission_id'] for row in db_admissions(db, ('a', 'b'))]
        turn.release.set()
        await _drained(authority)
    assert turn.taken == ['a\nb']
    assert _ledger(db) == [('running', 'terminal', 'completed'), ('a', 'terminal', 'steered'),
                           ('b', 'terminal', 'steered')]


def db_admissions(db, request_ids):
    from hermes_state_runtime import list_session_admissions
    by_request = {row['request_id']: row for row in list_session_admissions(db, session_id='s', pending_only=False)}
    return [by_request[request_id] for request_id in request_ids]


@pytest.mark.asyncio
async def test_a_message_the_turn_never_drained_goes_back_to_the_queue_and_runs_once_as_the_next_turn(
        bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch, drain=False)
    with db:
        conn = _owner_connection(authority)
        await _submit_as_owner(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        assert (await _submit_as_owner(conn, 'late'))['status'] == 'steered'
        turn.release.set()
        await async_wait_until(lambda: turn.ran == ['running', 'late'], timeout=30, what='the returned prompt to run')
        await _drained(authority)
    assert turn.agent._pending_steer is None
    assert _ledger(db) == [('running', 'terminal', 'completed'), ('late', 'terminal', 'completed')]


@pytest.mark.asyncio
async def test_a_message_sent_while_the_turn_builds_its_agent_stays_queued_and_runs_next(bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch, adopt=False)
    with db:
        conn = _owner_connection(authority)
        await _submit_as_owner(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        assert (await _submit_as_owner(conn, 'early'))['status'] == 'queued'
        assert not authority.pending_steers
        turn.release.set()
        await async_wait_until(lambda: turn.ran == ['running', 'early'], timeout=30, what='the queued prompt to run')
        await _drained(authority)
    assert _ledger(db) == [('running', 'terminal', 'completed'), ('early', 'terminal', 'completed')]


@pytest.mark.asyncio
@pytest.mark.parametrize('title', ['Weekend plans', None], ids=['other-chat', 'untitled'])
async def test_a_session_that_is_not_the_bot_chat_keeps_its_queue_semantics(bot_chat, monkeypatch, title):
    db, authority = bot_chat
    db._execute_write(lambda conn: conn.execute('UPDATE sessions SET title=? WHERE id=?', (title, 's')))
    turn = Turn(monkeypatch, drain=True)
    with db:
        conn = _owner_connection(authority)
        first = await _submit_as_owner(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        second = await _submit_as_owner(conn, 'follow-up')
        assert 'status' in first and first['status'] == 'queued' and second['status'] == 'queued'
        assert turn.agent._pending_steer is None and not interrupt_mod.is_thread_yield_requested(RunningAgent.WORKER)
        turn.release.set()
        await async_wait_until(lambda: turn.ran == ['running', 'follow-up'], timeout=30, what='the FIFO to advance')
        await _drained(authority)
    assert turn.taken == [None, None]


@pytest.mark.asyncio
async def test_input_from_an_operator_is_never_absorbed_into_the_owners_turn(bot_chat, monkeypatch):
    db, authority = bot_chat
    turn = Turn(monkeypatch)
    operator = SessionActor('someone-else', 'owned', frozenset({'session:submit', 'session:control'}), 'cli')
    with db:
        conn = _owner_connection(authority)
        await _submit_as_owner(conn, 'running')
        await asyncio.wait_for(turn.claimed.wait(), 30)
        disposition = {}
        await authority.submit(operator, Submission(request_id='from-operator', ref=REF,
                                                    payload={'text': 'from-operator'}, intent='queue'),
                               _disposition=disposition)
        assert disposition == {} and turn.agent._pending_steer is None
        turn.release.set()
        await async_wait_until(lambda: turn.ran == ['running', 'from-operator'], timeout=30, what='the FIFO to advance')
        await _drained(authority)
