"""A cron routine's output reaches the Bot Chat row as a readable card, not a bare notification.

Failure cases this file pins:
- the output is cut or rewritten on its way into the stored row or the timeline wire (30,000 characters);
- the job name, status or finish time is missing from the row, or the model's instruction wrapper
  leaks into the text a reader sees;
- a failed run loses its reason, or reads as a success;
- the model stops receiving the wrapper ("scheduled job, not the user");
- a row an older client cannot read as a person's message stops being a machine row;
- a malformed card is admitted, or a replayed id conflicts on its finish time.
"""
import asyncio

import pytest

from tests.waiting import async_wait_until

from gateway.session_contract import SessionRef
from hermes_state_runtime import RuntimeStoreError, list_session_admissions

pytest_plugins = ['tests.gateway.test_session_bot_retry']

KEY = 'd' * 32
JOB = {'id': 'job1', 'name': 'Morning digest'}
FINISHED = 1_700_000_000.5


def _body(size=30000):
    line = '- **item** `x`: status ok, details recorded\n'
    return (line * (size // len(line) + 1))[:size]


async def _deliver(bot, body, *, for_failure=False, key=KEY, finished_at=FINISHED):
    from cron.scheduler_delivery import bot_chat_message
    from cron.scheduler_delivery_routine import bot_chat_routine
    from gateway.session_bot import deliver
    message = bot_chat_message(JOB, body)
    routine = bot_chat_routine(JOB, body, for_failure=for_failure, finished_at=finished_at)
    await deliver(bot.connection, dict(id=key, profile='default', message=message, routine=routine,
                                       **({'notification_category': 'diagnostic'} if for_failure else {})))
    return message


def _persist_as_the_turn_does(bot, key=KEY):
    """The stored user row of the admitted routine turn: the event the drain restores, persisted with
    the display kind and metadata ``gateway/run_turn`` hands the agent."""
    from gateway.response_filters import display_kind_for_event, persisted_user_metadata_for_event
    from gateway.session_automation import pending_display_kind, restore_local_automation
    row = next(r for r in list_session_admissions(bot.authority.db, session_id=bot.chat, pending_only=False)
               if r['request_id'] == 'bot:' + key)
    event = restore_local_automation(bot.authority, SessionRef(bot.authority.profile_id, bot.chat), row)
    kind = display_kind_for_event(event)
    bot.authority.db.append_message(bot.chat, 'user', event.text, display_kind=kind,
                                    display_metadata=persisted_user_metadata_for_event(event))
    return event, pending_display_kind(row['payload'])


def _wire_entry(bot):
    from gateway.session_timeline import load_timeline
    entries = load_timeline(str(bot.home), bot.authority.db, bot.chat, None).entries
    return next(e for e in entries if e['role'] == 'user')


@pytest.mark.asyncio
async def test_routine_output_of_30000_chars_reaches_the_row_and_the_wire_whole(bot):
    body = _body()
    message = await _deliver(bot, body)
    event, pending_kind = _persist_as_the_turn_does(bot)
    assert pending_kind == 'routine_output'
    assert event.text == message and event.text.startswith('[Cronjob "Morning digest" output')
    assert 'scheduled job, not the user. Review it' in event.text

    entry = _wire_entry(bot)
    assert entry['display_kind'] == 'routine_output'
    card = entry['display_metadata']
    assert card['display_text'] == body and len(card['display_text']) == 30000
    assert 'scheduled job, not the user' not in card['display_text']
    assert (card['job_name'], card['status'], card['finished_at']) == ('Morning digest', 'ok', FINISHED)
    assert entry['text'] == message


@pytest.mark.asyncio
async def test_failed_routine_carries_its_reason_as_plain_text(bot):
    reason = 'Morning digest could not finish: the model service was unavailable.'
    await _deliver(bot, reason, for_failure=True)
    _persist_as_the_turn_does(bot)
    card = _wire_entry(bot)['display_metadata']
    assert (card['status'], card['display_text']) == ('failed', reason)


@pytest.mark.asyncio
async def test_row_stays_a_machine_row_an_older_client_shows_as_a_notification(bot):
    from gateway.display_markers import owner_display_text
    from gateway.response_filters import is_machinery_display_kind
    await _deliver(bot, _body(500))
    _persist_as_the_turn_does(bot)
    entry = _wire_entry(bot)
    assert entry['role'] == 'user' and entry['text'].strip() and entry['display_kind'] not in (None, 'steer')
    assert is_machinery_display_kind(entry['display_kind'])
    assert owner_display_text('user', entry['text'], entry['display_kind']) is None


@pytest.mark.asyncio
async def test_delivery_without_a_card_keeps_the_generic_notification_kind(bot):
    from gateway.session_bot import deliver
    await deliver(bot.connection, dict(id=KEY, profile='default', message='plain report'))
    _, pending_kind = _persist_as_the_turn_does(bot)
    assert pending_kind == 'internal_notification'
    entry = _wire_entry(bot)
    assert entry['display_kind'] == 'internal_notification' and 'display_metadata' not in entry


@pytest.mark.asyncio
@pytest.mark.parametrize('mutate', [
    lambda r: r.update(status='weird'),
    lambda r: r.update(finished_at=0),
    lambda r: r.update(finished_at=True),
    lambda r: r.update(job_name='  '),
    lambda r: r.update(text='x' * (1024 * 1024 + 1)),
    lambda r: r.update(extra=1),
    lambda r: r.pop('finished_at'),
])
async def test_malformed_card_is_refused_before_anything_is_admitted(bot, mutate):
    from gateway.session_bot import deliver
    routine = dict(job_name='Job', status='ok', finished_at=FINISHED, text='body')
    mutate(routine)
    with pytest.raises(RuntimeStoreError, match='invalid_params'):
        await deliver(bot.connection, dict(id=KEY, profile='default', message='body', routine=routine))
    assert list_session_admissions(bot.authority.db, session_id=bot.chat, pending_only=False) == []


@pytest.mark.asyncio
async def test_replayed_id_with_a_later_finish_time_answers_the_first_admission(bot):
    from tools.bot_live_delivery import read_delivery_result
    await _deliver(bot, 'report')
    await async_wait_until(lambda: (read_delivery_result(bot.home, KEY) or {}).get('status') == 'settled',
                           timeout=10, what='the routine delivery to settle')
    again = await _deliver(bot, 'report', finished_at=FINISHED + 60)
    assert again.endswith('report')
    assert len(list_session_admissions(bot.authority.db, session_id=bot.chat, pending_only=False)) == 1
    await asyncio.sleep(0)


def test_cron_card_is_scrubbed_named_and_bounded():
    from cron.scheduler_delivery_routine import bot_chat_routine
    assert bot_chat_routine(JOB, '  \n', for_failure=False, finished_at=FINISHED) is None
    assert bot_chat_routine(JOB, 'out', for_failure=False, finished_at=None) is None
    long_name = bot_chat_routine({'id': 'j', 'name': 'n' * 500}, 'out', for_failure=True, finished_at=FINISHED)
    assert len(long_name['job_name']) == 200 and long_name['status'] == 'failed'
    assert bot_chat_routine({'id': 'j7', 'name': ''}, 'out', for_failure=False, finished_at=FINISHED)['job_name'] == 'j7'
    leaked = bot_chat_routine(JOB, 'key sk-ant-api03-' + 'a' * 40, for_failure=False, finished_at=FINISHED)
    assert 'sk-ant-api03-' + 'a' * 40 not in leaked['text']
