import pytest

from gateway.session_cli_turn import cli_turn_scope

from tests.gateway.test_local_viewer_events_submit import _gateway_runner, _run_turn
from tests.gateway.test_surface_admission import _authority

NOTE = '[@mentions resolved from the Bot Mode roster: @faker-kit = agent profile "faker-kit"]'


@pytest.mark.asyncio
async def test_the_note_is_committed_cleaned_and_refused_when_malformed(tmp_path, monkeypatch):
    from gateway.session_controls import AuthorityConnection
    from hermes_state_runtime import list_session_admissions

    async def answer(event):
        return 'ok'
    authority = await _authority(tmp_path, monkeypatch, answer)
    connection = AuthorityConnection(authority, object(), {'user_id': 'owner'})
    try:
        await connection.dispatch({'id': 1, 'method': 'session.resume', 'params': {'session_id': 's'}})
        for rid, note in (('padded', f'  {NOTE}\n'), ('blank', '  \n'), ('huge', 'x' * 9000)):
            reply = await connection.dispatch({'id': 2, 'method': 'prompt.submit', 'params': {
                'session_id': 's', 'submission_id': rid, 'text': rid, 'turn_context': note}})
            assert reply.get('result', {}).get('status') == 'queued', reply
            await authority.sessions['s'].task
        refused = await connection.dispatch({'id': 3, 'method': 'prompt.submit', 'params': {
            'session_id': 's', 'submission_id': 'bad', 'text': 'x', 'turn_context': {'note': NOTE}}})
        assert refused['error']['message'] == 'invalid_params'
    finally:
        await connection.close()
    rows = {row['request_id']: row for row in list_session_admissions(authority.db, session_id='s', pending_only=False)}
    assert rows['padded']['payload']['cli_turn_v1'] == {'turn_context': NOTE}
    assert 'cli_turn_v1' not in rows['blank']['payload']
    assert rows['huge']['payload']['cli_turn_v1'] == {'turn_context': 'x' * 4000}
    assert 'bad' not in rows


def test_the_model_message_ends_with_the_note_and_the_persisted_row_stays_the_typed_text():
    runner = _gateway_runner()
    with cli_turn_scope('adm-1', {'turn_context': NOTE}):
        _result, agent = _run_turn(runner)
    [(message, kwargs)] = agent.calls
    assert message == f'clean text\n\n{NOTE}' and kwargs['persist_user_message'] == 'clean text'

    with cli_turn_scope('adm-1', {'turn_context': NOTE}):
        _result, agent = _run_turn(runner, admission_id='adm-2')
    [(message, kwargs)] = agent.calls
    assert message == 'clean text' and 'persist_user_message' not in kwargs


def test_the_note_follows_the_cli_api_text_when_both_are_committed():
    with cli_turn_scope('adm-1', {'api_text': '[voice] clean text', 'turn_context': NOTE}):
        _result, agent = _run_turn(_gateway_runner())
    [(message, kwargs)] = agent.calls
    assert message == f'[voice] clean text\n\n{NOTE}' and kwargs['persist_user_message'] == 'clean text'
