import asyncio
from types import SimpleNamespace

import pytest
import pytest_asyncio

from gateway.session_contract import SessionRef
from gateway.session_finite import execute_finite_admission as real_execute
from tests.fixtures.storage_read import transcript_rows
from tests.fixtures.storage_seed import seed_messages
from tests.waiting import async_wait_until

pytest_plugins = ['tests.gateway.test_session_bot_retry']

JOB = {'id': '3f9a2c1d4e5b', 'name': 'daily_report_job', 'execution_id': 'exec-1'}
OUTPUT = 'Revenue is up 4%.\n\n- churn is flat'


@pytest_asyncio.fixture
async def routine(bot, monkeypatch):
    from gateway.session_bot import deliver
    from gateway.session_cron import bind_owner
    from gateway.session_local_recovery import local_adapter
    from gateway.session_results import execution_result
    from tools import bot_live_delivery as mailbox
    from tui_gateway.contracts.registry import CANONICAL_METHODS, canonical_param_problems

    authority, runner = bot.authority, bot.authority.runner
    turns, replies = [], []
    loop = asyncio.get_running_loop()

    async def model_turn(event):
        turns.append(event.text)
        execution_result.get()['result'] = {'final_response': 'a second answer', 'completed': True, 'messages': []}
        return 'a second answer'

    monkeypatch.setattr('gateway.session_finite.execute_finite_admission', real_execute)
    runner._handle_message = model_turn
    runner._session_key_for_source = runner.session_store._generate_session_key
    runner.session_authority = authority
    local_adapter(authority)
    runner._adapter_for_source = lambda source: runner.adapters.get(source.platform)
    stream = type(authority.sessions[bot.chat].event_stream)
    publish = stream.publish

    def record(self, session_id, payload, *, event_type='message.complete', execution=None):
        if event_type == 'message.complete':
            replies.append(payload.get('text'))
        return publish(self, session_id, payload, event_type=event_type, execution=execution)

    monkeypatch.setattr(stream, 'publish', record)
    monkeypatch.setattr(mailbox, 'find_canonical_live_owner', lambda home: dict(
        profile_home=str(bot.home), session_id=bot.chat, lease_id='x', live_session_id=bot.chat))
    def over_the_wire(home, params):
        problems = canonical_param_problems(CANONICAL_METHODS['bot_relay.deliver'], params)
        assert not problems, problems
        return asyncio.run_coroutine_threadsafe(deliver(bot.connection, params), loop).result(30)

    monkeypatch.setattr(mailbox, 'authority_delivery', over_the_wire)
    bind_owner(authority)
    return SimpleNamespace(bot=bot, authority=authority, turns=turns, replies=replies)


async def _drained(routine):
    await async_wait_until(
        lambda: not routine.authority.persistence.admissions.list(session_id=routine.bot.chat)
        and all(live.task is None or live.task.done() for live in routine.authority.sessions.values()),
        timeout=10, what='the routine delivery to settle')


def _shown(routine):
    from gateway.session_controls import display_projection
    from gateway.session_local_recovery import local_history
    authority = routine.authority
    rows = local_history(authority, SessionRef(authority.profile_id, routine.bot.chat))
    return [(m['role'], m['text']) for m in display_projection(list(rows), authority.profile_id)]


def _stored(routine):
    return transcript_rows(routine.authority.persistence, routine.bot.chat)


async def _bot_chat_run(routine, content=OUTPUT, **kwargs):
    from cron.scheduler_delivery import _deliver_to_bot_chat
    error = await asyncio.to_thread(_deliver_to_bot_chat, kwargs.pop('job', dict(JOB)), content, '', **kwargs)
    assert error is None or ' queued (receipt ' in error, error
    await _drained(routine)


async def _local_chat_run(routine, job, content=OUTPUT):
    from cron.scheduler_delivery import _deliver_result
    origin = {'platform': 'local', 'chat_id': routine.bot.chat}
    error = await asyncio.to_thread(_deliver_result, {**job, 'deliver': 'origin', 'origin': origin}, content)
    assert error is None, error
    await _drained(routine)


@pytest.mark.asyncio
async def test_one_run_is_one_assistant_message_and_no_model_turn(routine):
    await _bot_chat_run(routine)
    assert routine.turns == []
    assert _shown(routine) == [('assistant', OUTPUT)]
    assert routine.replies == [OUTPUT]
    assert not any(row.get('display_kind') == 'routine_output' for row in _stored(routine))


@pytest.mark.asyncio
async def test_local_chat_run_is_the_same_unlabelled_message(routine):
    await _local_chat_run(routine, dict(JOB))
    assert routine.turns == []
    assert _shown(routine) == [('assistant', OUTPUT)]
    assert routine.replies == [OUTPUT]


@pytest.mark.asyncio
async def test_a_retry_and_a_second_lane_write_nothing_more(routine):
    await _bot_chat_run(routine)
    await _bot_chat_run(routine)
    await _local_chat_run(routine, dict(JOB))
    assert routine.turns == []
    assert _shown(routine) == [('assistant', OUTPUT)]
    assert [text for text in routine.replies if text] == [OUTPUT]
    await _bot_chat_run(routine, 'Next day.', job={**JOB, 'execution_id': 'exec-2'})
    assert _shown(routine) == [('assistant', OUTPUT), ('assistant', 'Next day.')]


@pytest.mark.asyncio
async def test_failed_run_is_one_diagnostic_message_without_a_label(routine):
    reason = 'The model service was unreachable.'
    await _bot_chat_run(routine, reason, for_failure=True)
    assert routine.turns == []
    assert _shown(routine) == [('assistant', reason)]
    row = next(row for row in _stored(routine) if row['role'] == 'assistant')
    assert row['display_metadata']['notification_category'] == 'diagnostic'
    assert 'daily' not in str(_shown(routine)).lower()


@pytest.mark.asyncio
async def test_the_next_model_call_keeps_the_message_as_its_own_turn(routine):
    seed_messages(routine.authority.persistence, routine.bot.chat,
                  {'role': 'user', 'content': 'hi'}, {'role': 'assistant', 'content': 'hello'})
    await _bot_chat_run(routine)
    assert [row['role'] for row in _stored(routine)] == ['user', 'assistant', 'user', 'assistant']
    assert _shown(routine) == [('user', 'hi'), ('assistant', 'hello'), ('assistant', OUTPUT)]


@pytest.mark.asyncio
async def test_stored_routine_output_row_reads_as_plain_assistant_text(routine):
    seed_messages(routine.authority.persistence, routine.bot.chat, {
        'role': 'user', 'content': '[Cronjob "daily_report_job" output] wrapper', 'display_kind': 'routine_output',
        'display_metadata': {'display_text': OUTPUT, 'job_name': 'daily_report_job', 'status': 'ok',
                             'finished_at': 1.0}})
    assert _shown(routine) == [('assistant', OUTPUT)]


def test_an_admission_queued_before_the_upgrade_is_posted_not_answered():
    from gateway.session_cron_post import cron_post
    post = cron_post({'local_automation_v1': {
        'identity': 'bot:abc', 'display_kind': 'routine_output', 'display_text': OUTPUT,
        'routine': {'job_name': 'daily_report_job', 'status': 'ok', 'finished_at': 1.0}}})
    assert (post.execution_id, post.name, post.text) == ('bot:abc', 'Daily report job', OUTPUT)


@pytest.mark.asyncio
async def test_run_lost_in_a_restart_is_still_posted_once(tmp_path, monkeypatch):
    from tests.gateway.test_unknown_automation_settles import _lost_head_then_restart

    async def cron_head(authority, _actor, _ref):
        row, _created = authority.persistence.admissions.admit(
            epoch=authority.epoch, principal_id='automation:agent:main:telegram:dm:gw10', session_id='s',
            request_id='cron:job:exec-1', payload={'text': 'HEAD', 'local_automation_v1': {
                'identity': 'cron:job:exec-1', 'owner': 's', 'cron_delivery': {
                    'job_id': 'job', 'execution_id': 'exec-1', 'name': 'Daily report', 'text': OUTPUT}}})
        return row.admission_id

    executed = []
    store, _authority, _head, _follower = await _lost_head_then_restart(tmp_path, monkeypatch, executed, cron_head)
    try:
        rows = transcript_rows(store.persistence, 's')
        assert [row['content'] for row in rows if row['role'] == 'assistant'].count(OUTPUT) == 1
        assert not any('interrupted' in str(row['content']).lower() for row in rows)
    finally:
        store.close_all_db_handles()
