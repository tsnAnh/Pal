"""A chat turn that cannot start because no AI provider is set up carries a stable
``error_surface.code`` live and on the durable failed-turn row, so a client draws its own
"connect a model" card without reading the CLI sentence. Other platforms keep their text."""
import json
from types import SimpleNamespace

import pytest

from gateway.config import Platform
from hermes_cli.auth import AuthError
from tests.fixtures.storage_seed import seed_session

_NO_PROVIDER = AuthError("Hermes is not connected to any AI provider yet.", code="no_provider_configured")


def _resolution_failure(platform, cause):
    from gateway.run_turn_runner import TurnRunner
    from gateway.session import SessionSource
    from gateway.session_results import execution_result
    from gateway.turn_context import TurnContext
    from tests.gateway.test_local_viewer_events_submit import _gateway_runner

    runner = _gateway_runner()
    error = RuntimeError(str(cause))
    error.__cause__ = cause
    runner._resolve_session_agent_runtime.side_effect = error
    ctx = TurnContext(
        source=SessionSource(platform=platform, chat_id='sid', user_id='u'),
        message='hi', history=[], session_id='sid', session_key='key', user_config={},
        resolve_display_setting=lambda *_a: False, _run_still_current=lambda: True)
    captured = {}
    token = execution_result.set(captured)
    try:
        result = TurnRunner(runner, ctx).run_sync()
    finally:
        execution_result.reset(token)
    return result, {'result': result, 'usage': {}}


def test_local_turn_without_a_provider_completes_with_the_code_and_commits_it_on_the_boundary():
    from gateway.session_settlement_recovery import completion_payload, gateway_refusal_boundary

    result, captured = _resolution_failure(Platform.LOCAL, _NO_PROVIDER)
    assert result['failed'] and not result['completed']
    complete = completion_payload({'admission_id': 'a1', 'request_id': 'r1'}, {'outcome': 'failed'},
                                  result['final_response'], captured)
    assert complete['status'] == 'error'
    assert complete['error_surface']['code'] == 'no_provider_configured'
    notice, metadata = gateway_refusal_boundary(captured, 'failed')
    assert notice == result['error']
    assert metadata['error_surface']['code'] == 'no_provider_configured'


@pytest.mark.parametrize('platform, cause', [
    (Platform.TELEGRAM, _NO_PROVIDER),
    (Platform.LOCAL, AuthError('token expired', code='token_expired')),
])
def test_other_failures_carry_no_connect_a_model_code(platform, cause):
    result, _captured = _resolution_failure(platform, cause)
    assert result['failed'] and 'error_surface' not in result


_PRODUCT_COPY = "Needs an AI model to reply"


async def _settled_resolution_failure(owner, platform, cause, text="hello", redeliveries=1):
    """The user's send through the real persist + settle seams, over the owner's real state.db."""
    from gateway.platforms.event import MessageEvent
    from gateway.run import GatewayRunner
    from gateway.session import SessionSource
    from gateway.session_authority import admission_row
    from gateway.session_persistence import authority_persistence
    from gateway.session_display import submission_turn_scope
    from gateway.session_results import finish_result

    store = owner.runner.session_store
    runner = object.__new__(GatewayRunner)
    runner.session_store = store
    runner._session_db = object()

    async def noop(*_a, **_k):
        return None

    runner._refresh_agent_cache_message_count = noop
    source = SessionSource(platform=platform, chat_id='local-chat', user_id='u')
    sid = seed_session(owner.persistence, 'local-session', 'local', chat_id='local-chat', user_id='u')
    entry = SimpleNamespace(session_id=sid, session_key='local:unregistered')
    owner.persistence.admissions.admit(epoch=owner.epoch, principal_id='desktop-user', session_id=sid,
                                       request_id='send-1', payload={'text': text})
    row = admission_row(owner.persistence.admissions.claim(epoch=owner.epoch, session_id=sid))
    result, captured = _resolution_failure(platform, cause)
    event = MessageEvent(text=text, source=source, message_id=row['admission_id'])
    prepared = runner._PreparedTurn([], '', text, None, None, None, sid, 'owner')
    for _ in range(redeliveries):
        with submission_turn_scope(row['admission_id'], 'send-1'):
            await runner._hmwa_persist_turn_transcript(
                event=event, source=source, session_entry=entry, session_key=entry.session_key,
                agent_result=result, agent_messages=[], prepared=prepared, response=result['final_response'],
                agent_failed_early=True, hidden_reasoning_incomplete=False, is_context_overflow_failure=False)
    settled = finish_result(authority_persistence(owner), epoch=owner.epoch, row=row,
                            response=result['final_response'], outcome='failed', result=captured)
    return sid, settled


def _history(owner, sid):
    from tests.fixtures.storage_read import transcript_rows
    return [m for m in transcript_rows(owner.persistence, sid) if m['role'] != 'session_meta']


def _metadata(row):
    value = row['display_metadata']
    return json.loads(value) if isinstance(value, str) else value


@pytest.mark.asyncio
async def test_no_provider_turn_keeps_the_users_message_before_its_error_card(owner):
    sid, _settled = await _settled_resolution_failure(owner, Platform.LOCAL, _NO_PROVIDER)
    history = _history(owner, sid)
    assert [(m['role'], m['content']) for m in history[:1]] == [('user', 'hello')]
    assert [m['role'] for m in history] == ['user', 'assistant']
    user, card = history
    assert user['display_metadata']['submission_id'] == 'send-1'
    assert card['display_kind'] == 'failed_turn'
    assert _metadata(card)['error_surface']['code'] == 'no_provider_configured'
    assert card['id'] > user['id']


@pytest.mark.asyncio
@pytest.mark.parametrize('platform, cause', [
    (Platform.LOCAL, AuthError('token expired', code='token_expired')),
    (Platform.TELEGRAM, _NO_PROVIDER),
])
async def test_any_resolution_failure_keeps_the_users_message_and_closes_the_turn(owner, platform, cause):
    sid, _settled = await _settled_resolution_failure(owner, platform, cause)
    history = _history(owner, sid)
    assert [(m['role'], m['content']) for m in history[:1]] == [('user', 'hello')]
    assert [m['role'] for m in history] == ['user', 'assistant']
    assert history[-1]['display_kind'] == 'failed_turn'
    assert 'error_surface' not in (_metadata(history[-1]) or {})


@pytest.mark.asyncio
async def test_a_redelivered_resolution_failure_adds_no_second_user_row_or_boundary(owner):
    sid, _settled = await _settled_resolution_failure(owner, Platform.LOCAL, _NO_PROVIDER, redeliveries=2)
    assert [m['role'] for m in _history(owner, sid)] == ['user', 'assistant']


@pytest.mark.asyncio
async def test_the_bot_preview_reads_product_copy_not_the_cli_sentence(owner):
    sid, _settled = await _settled_resolution_failure(owner, Platform.LOCAL, _NO_PROVIDER)
    messages = owner.persistence.messages
    assert 'AI provider' in _history(owner, sid)[-1]['content']
    assert messages.latest_dialogue_message(sid, owner_visible=True) == _PRODUCT_COPY
    assert messages.latest_dialogue_message(sid) == _history(owner, sid)[-1]['content']


@pytest.mark.asyncio
async def test_the_authority_roster_preview_reads_product_copy_for_the_error_card(owner):
    await _settled_resolution_failure(owner, Platform.LOCAL, _NO_PROVIDER)
    roster = owner.persistence.sessions.roster_sessions(owner_user_id=None, owner=None)
    assert roster.last_session.preview == _PRODUCT_COPY


@pytest.mark.parametrize('metadata, shown', [
    ({'error': 'boom', 'error_surface': {'code': 'no_provider_configured'}}, _PRODUCT_COPY),
    (json.dumps({'error': 'boom', 'error_surface': {'code': 'no_provider_configured'}}), _PRODUCT_COPY),
    ({'error': 'boom', 'error_surface': {'code': 'token_expired'}}, 'boom'),
    ({'error': 'boom', 'error_surface': {'code': ['no_provider_configured']}}, 'boom'),
    ({'error': 'boom'}, 'boom'),
    ('not json', 'boom'),
    (None, 'boom'),
])
def test_only_a_failed_turn_row_with_preview_copy_is_rewritten_for_the_preview(metadata, shown):
    from gateway.display_markers import owner_display_text
    assert owner_display_text('assistant', 'boom', 'failed_turn', metadata) == shown
    assert owner_display_text('assistant', 'boom', None, metadata) == 'boom'
