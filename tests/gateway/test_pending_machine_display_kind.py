"""A machine-injected turn reaches a viewer as the notice its stored row becomes, on every live wire.

A queued or running admission lists to viewers (``session.resume`` / ``session.info`` ``pending``)
with the ``display_kind`` its persisted user row will carry, so a client never has to guess from the
model-facing text whether the owner wrote it. Pal painted an async-delegation completion as the
owner's own bubble because the pending entry carried no kind.
"""
import asyncio

import pytest
import pytest_asyncio

from tests.gateway.test_local_producer_admission import _Gateway


@pytest_asyncio.fixture
async def gateway(tmp_path, monkeypatch):
    running = _Gateway(tmp_path, monkeypatch)
    await running.start()
    try:
        yield running
    finally:
        if running.gate is not None:
            running.gate.set()
        await running.stop()


async def _pending(gateway, session_id):
    viewer = gateway.connect(gateway.primary)
    reply = await viewer.dispatch({'id': 'r', 'method': 'session.resume', 'params': {'session_id': session_id}})
    return reply['result']['pending']


@pytest.mark.asyncio
async def test_a_queued_process_completion_lists_with_its_notice_kind(gateway):
    owner = gateway.connect(gateway.primary)
    sid = gateway.create(gateway.primary, owner, 'desktop', 'gui').session_id
    resumed = await owner.dispatch({'id': 0, 'method': 'session.resume', 'params': {'session_id': sid}})
    assert 'result' in resumed, resumed
    gateway.gate = asyncio.Event()
    submitted = await owner.dispatch({'id': 1, 'method': 'prompt.submit', 'params': {
        'session_id': sid, 'input_id': 'mine', 'text': 'run the job in the background'}})
    assert 'result' in submitted, submitted
    completion = gateway.process_event(gateway.primary, sid, 'completion', exit_code=2)
    assert await gateway.runner._deliver_completion_notification('[job finished]', completion) is True

    pending = await _pending(gateway, sid)
    kinds = {entry['input_id'] == 'mine': entry.get('display_kind') for entry in pending}
    assert kinds == {True: None, False: 'process_complete'}, pending
    gateway.gate.set()
    await gateway.settled(gateway.primary, sid, 2)


@pytest.mark.parametrize(('descriptor', 'expected'), [
    ({'display_kind': 'async_delegation_complete', 'display_text': 'Background delegation finished'},
     'async_delegation_complete'),
    ({'display_kind': 'process_complete', 'display_text': 'Background process finished'}, 'process_complete'),
    ({'display_kind': 'internal_notification', 'display_text': 'Background Process Output after 1m'},
     'internal_notification'),
    ({}, 'internal_notification'),
])
@pytest.mark.parametrize('lane', ['local_automation_v1', 'native_text_v1'])
def test_every_automation_admission_lists_with_the_kind_its_stored_row_gets(descriptor, expected, lane):
    from gateway.session_automation import pending_display_kind
    automation = {'identity': 'id-1', 'owner': 's1', **descriptor}
    payload = ({'text': 'model text', 'local_automation_v1': automation} if lane == 'local_automation_v1'
               else {'text': 'model text', 'native_text_v1': {'automation': automation}})
    assert pending_display_kind(payload) == expected


def test_a_hidden_widget_intent_lists_hidden_and_an_owner_message_lists_no_kind():
    from gateway.session_automation import pending_display_kind
    assert pending_display_kind({'text': 'kickoff', 'display_v1': {'kind': 'hidden'}}) == 'hidden'
    assert pending_display_kind({'text': 'hello'}) is None
    assert pending_display_kind({'text': 'hello', 'display_v1': {'title_preview': 'hello'}}) is None


def test_an_absorbed_steer_names_the_kind_of_the_row_it_became():
    from agent.steer_absorb import deliver_steer_row
    from types import SimpleNamespace
    seen = []
    agent = SimpleNamespace(_steer_last_drain=('also check totals', [('adm-1', 'also check totals')]),
                            input_absorbed_callback=lambda **event: seen.append(event))
    messages = []
    deliver_steer_row(agent, messages, 'also check totals')
    assert [event['display_kind'] for event in seen] == [messages[0]['display_kind']] == ['steer']


def test_the_roster_preview_never_reads_a_machine_turn():
    from gateway.display_markers import owner_display_text
    delegation = '[ASYNC DELEGATION BATCH COMPLETE — deleg_1] A background fan-out unit finished.'
    for kind in ('async_delegation_complete', 'process_complete', 'internal_notification', 'hidden',
                 'model_switch', 'personality_switch'):
        assert owner_display_text('user', 'machine text', kind) is None, kind
    assert owner_display_text('user', delegation) is None
    assert owner_display_text('user', 'hello there') == 'hello there'
    assert owner_display_text('user', 'also check totals', 'steer') == 'also check totals'
