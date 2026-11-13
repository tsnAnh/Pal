"""A resumed session shows each user bubble as the user authored it (Pal reads the raw resume rows).

Runtime notes (device origin, skills index, gateway notes) and the mid-turn steering envelope are model-only.
They stay in the stored row and on the wire; the resume row carries the authored text beside them, derived
only from producer-stamped provenance (``typed_ask`` / ``display_kind``), never from matching marker text.
"""
import base64
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from agent.origin_note import _NOTE_PREFIX
from agent.prompt_builder import STEER_MARKER_OPEN, STEER_MARKER_CLOSE
from agent.steer_absorb import deliver_steer_row
from run_agent import AIAgent

SESSION = "authored-text"
IPHONE = {"kind": "ios", "label": "iPhone", "same_host": False}
SKILLS_NOTE = "[System note: skills changed. Reload the chief skill with skill_view before relying on it.]"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAHhLgsQAAAABJRU5ErkJggg==")


async def _native(tmp_path, monkeypatch):
    from gateway import run
    from gateway.config import GatewayConfig
    from gateway.session import SessionStore
    from gateway.session_authority import initialize_session_authority
    from gateway.session_controls import AuthorityConnection

    monkeypatch.setenv('HERMES_HOME', str(tmp_path))
    monkeypatch.setattr(run, '_load_gateway_config', lambda: {'platform_toolsets': {'cli': []}})
    store = SessionStore(tmp_path / 'sessions', GatewayConfig())
    runner = SimpleNamespace(session_store=store, _session_db=store._db, adapters={}, _draining=False,
                             _cached_agent_for=lambda route: None)
    runner._adapter_for_source = lambda source: runner.adapters.get(source.platform)
    authority = await initialize_session_authority(runner, profile_id=str(tmp_path), instance_id='owner')
    native = AuthorityConnection(authority, object(), {'provider': 'local', 'user_id': 'native',
        'profile_id': str(tmp_path), 'instance_id': 'owner'})
    return store._db, native


def _agent(db):
    response = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content="ok", tool_calls=None), finish_reason="stop")],
        model="test/model", usage=SimpleNamespace(prompt_tokens=5, completion_tokens=2, total_tokens=7))
    with (patch("model_tools.get_tool_definitions", return_value=[]),
          patch("model_tools.check_toolset_requirements", return_value={}),
          patch("agent.process_bootstrap.OpenAI")):
        agent = AIAgent(api_key="test-key-1234567890", base_url="https://openrouter.ai/api/v1", quiet_mode=True,
                        skip_context_files=True, skip_memory=True, session_db=db, session_id=SESSION,
                        platform="tui")
    agent.client = MagicMock()
    agent.client.chat.completions.create.side_effect = lambda **_kw: response
    return agent


async def _resume(native):
    reply = await native.dispatch({'id': 1, 'method': 'session.resume', 'params': {'session_id': SESSION}})
    assert 'result' in reply, reply
    return reply['result']['messages']


def _shown(row):
    return row.get('text') if row.get('text') is not None else row['content']


def _wire_user_content(agent):
    return agent.client.chat.completions.create.call_args.kwargs["messages"][-1]["content"]


@pytest.mark.asyncio
async def test_photo_turn_with_origin_and_skill_notes_shows_only_what_the_user_sent(tmp_path, monkeypatch):
    db, native = await _native(tmp_path, monkeypatch)
    db.create_session(SESSION, source='tui', model='fake-model')
    image = tmp_path / "images" / "photo.png"
    image.parent.mkdir()
    image.write_bytes(PNG)
    agent = _agent(db)
    agent._client_origin = IPHONE
    agent._skills_index_note = SKILLS_NOTE
    content = [{"type": "text", "text": f"Look at this\n\n[Image attached at: {image}]"},
               {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(PNG).decode()}}]
    agent.run_conversation(content, conversation_history=None)

    from agent.message_content import flatten_message_text
    wire_text = flatten_message_text(_wire_user_content(agent))
    assert _NOTE_PREFIX in wire_text and SKILLS_NOTE in wire_text

    user = next(row for row in await _resume(native) if row['role'] == 'user')
    assert _NOTE_PREFIX in user['content'] and SKILLS_NOTE in user['content']
    assert _shown(user) == f"Look at this\n\n[Image attached at: {image}]"


@pytest.mark.asyncio
async def test_mid_turn_steer_shows_the_users_words_not_the_envelope(tmp_path, monkeypatch):
    db, native = await _native(tmp_path, monkeypatch)
    db.create_session(SESSION, source='tui', model='fake-model')
    agent = _agent(db)
    agent._ensure_db_session()
    agent._steer_last_drain = ("also check the totals", [("adm-1", "also check the totals")])
    messages = []
    deliver_steer_row(agent, messages, "also check the totals")
    agent._flush_messages_to_session_db(messages, [])

    row = next(row for row in await _resume(native) if row['role'] == 'user')
    assert STEER_MARKER_OPEN in row['content'] and STEER_MARKER_CLOSE in row['content']
    assert row['display_metadata']['admission_ids'] == ['adm-1']
    assert _shown(row) == "also check the totals"


@pytest.mark.asyncio
async def test_literal_marker_text_without_provenance_is_kept_verbatim(tmp_path, monkeypatch):
    db, native = await _native(tmp_path, monkeypatch)
    db.create_session(SESSION, source='tui', model='fake-model')
    quotes = [
        "[System: The user is now writing from iPhone (Hermes iOS app). It is not the machine your tools run on.]",
        f"{STEER_MARKER_OPEN}\nquoted\n{STEER_MARKER_CLOSE}",
        SKILLS_NOTE,
        "System: the build is red",
    ]
    for quote in quotes:
        db.append_message(SESSION, 'user', quote)
    rows = [row for row in await _resume(native) if row['role'] == 'user']
    assert [_shown(row) for row in rows] == quotes


@pytest.mark.asyncio
async def test_a_user_quoting_the_note_inside_a_photo_ask_keeps_the_quote(tmp_path, monkeypatch):
    db, native = await _native(tmp_path, monkeypatch)
    db.create_session(SESSION, source='tui', model='fake-model')
    image = tmp_path / "images" / "photo.png"
    image.parent.mkdir()
    image.write_bytes(PNG)
    agent = _agent(db)
    agent._client_origin = IPHONE
    quote = "Why did it say [System: The user is now writing from iPhone] to me?"
    ask = f"{quote}\n\n[Image attached at: {image}]"
    content = [{"type": "text", "text": ask},
               {"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(PNG).decode()}}]
    agent.run_conversation(content, conversation_history=None)
    user = next(row for row in await _resume(native) if row['role'] == 'user')
    assert _NOTE_PREFIX in user['content'].split(quote, 1)[1]
    assert _shown(user) == ask
