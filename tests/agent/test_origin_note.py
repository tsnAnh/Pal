"""The device a turn was typed on reaches the model as a per-turn note, only when it changes, and never
touches the system prompt bytes (fresh agent per turn, as the gateway builds it, and a warm agent)."""
from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from agent.origin_note import _NOTE_PREFIX
from agent.origin_note import stage_origin_note
from agent.turn_context import consume_origin_note
from hermes_state import SessionDB
from run_agent import AIAgent

SESSION = "origin-session"
DESKTOP = {"kind": "desktop", "label": "Desktop (macOS)", "same_host": True}
IPHONE = {"kind": "ios", "label": "iPhone", "same_host": False}
MAC_APP = {"kind": "mac", "label": "Mac", "same_host": False}
STORED_PROMPT = "Identity.\n\nConversation started: Monday\nPlatform: desktop"


def _response():
    message = SimpleNamespace(content="ok", tool_calls=None)
    return SimpleNamespace(choices=[SimpleNamespace(message=message, finish_reason="stop")], model="test/model",
                           usage=SimpleNamespace(prompt_tokens=5, completion_tokens=2, total_tokens=7))


def _agent(db, platform="desktop"):
    with (patch("model_tools.get_tool_definitions", return_value=[]),
          patch("model_tools.check_toolset_requirements", return_value={}),
          patch("agent.process_bootstrap.OpenAI")):
        agent = AIAgent(api_key="test-key-1234567890", base_url="https://openrouter.ai/api/v1", quiet_mode=True,
                        skip_context_files=True, skip_memory=True, session_db=db, session_id=SESSION,
                        platform=platform)
    agent.client = MagicMock()
    agent.client.chat.completions.create.side_effect = lambda **_kw: _response()
    return agent


def _request(agent):
    messages = agent.client.chat.completions.create.call_args.kwargs["messages"]
    system = next(m["content"] for m in messages if m["role"] == "system")
    return system, messages[-1]["content"]


def _noted(content):
    return _NOTE_PREFIX in content


def _drive(db, origins, *, warm, platform="desktop"):
    """Run one real turn per origin; returns the system bytes and the note-bearing user content of each."""
    sent, agent, history = [], None, None
    for index, origin in enumerate(origins):
        if agent is None or not warm:
            agent = _agent(db, platform)
        if not warm:
            history = db.get_messages_as_conversation(SESSION)
        agent._client_origin = origin
        result = agent.run_conversation(f"turn {index}", conversation_history=history or None)
        history = result["messages"] if warm else history
        sent.append(_request(agent))
    return sent


@pytest.fixture
def db(tmp_path):
    return SessionDB(db_path=tmp_path / "state.db")


@pytest.mark.parametrize("warm", [False, True], ids=["fresh-agent-per-turn", "warm-agent"])
def test_note_only_when_the_device_changes_and_system_bytes_never_move(db, warm):
    sent = _drive(db, [DESKTOP, IPHONE, IPHONE, DESKTOP], warm=warm)
    assert [_noted(content) for _system, content in sent] == [False, True, False, True]
    assert "iPhone (Hermes iOS app). It is not the machine your tools run on" in sent[1][1]
    assert "Desktop (macOS) (Hermes desktop app). It is the machine your tools run on." in sent[3][1]
    systems = {system for system, _content in sent}
    assert len(systems) == 1
    assert db.get_session(SESSION)["system_prompt"] == systems.pop()
    assert "Platform: desktop" in sent[0][0]


@pytest.mark.parametrize("warm", [False, True], ids=["fresh-agent-per-turn", "warm-agent"])
def test_phone_session_announces_the_phone_once(db, warm):
    sent = _drive(db, [IPHONE, IPHONE, IPHONE], warm=warm, platform="ios")
    assert [_noted(content) for _system, content in sent] == [True, False, False]
    assert "Platform: ios" in sent[0][0]
    assert "Hermes iOS app on an iPhone" in sent[0][0] and "::preview{" not in sent[0][0]


@pytest.mark.parametrize("warm", [False, True], ids=["fresh-agent-per-turn", "warm-agent"])
def test_a_mac_app_is_announced_as_itself_and_not_as_a_phone(db, warm):
    sent = _drive(db, [MAC_APP, MAC_APP, IPHONE], warm=warm)
    assert [_noted(content) for _system, content in sent] == [True, False, True]
    assert "Mac (Hermes Mac app). It is not the machine your tools run on" in sent[0][1]
    assert "This is a phone" not in sent[0][1]


@pytest.mark.parametrize("warm", [False, True], ids=["fresh-agent-per-turn", "warm-agent"])
def test_turns_without_a_declared_device_never_get_a_note(db, warm):
    sent = _drive(db, [None, None, DESKTOP, None], warm=warm)
    assert not any(_noted(content) for _system, content in sent)


def _stage(origin, history, *, prompt=STORED_PROMPT, **agent_attrs):
    agent = SimpleNamespace(session_id="s", provider="openrouter", api_mode="chat_completions",
                            _client_origin=origin, **agent_attrs)
    staged = stage_origin_note(agent, prompt, history)
    note = consume_origin_note(agent)
    assert staged is bool(note)
    history.append({"role": "user", "content": "hi", **({"api_content": f"hi\n\n{note}"} if note else {})})
    history.append({"role": "assistant", "content": "ok"})
    return note


def test_a_note_beyond_the_scan_window_or_lost_to_compaction_reannounces_once():
    history = []
    assert _stage(DESKTOP, history) == ""
    assert _stage(IPHONE, history) != ""
    assert _stage(IPHONE, history) == ""
    history += [{"role": "user", "content": "x"}, {"role": "assistant", "content": "y"}] * 150
    assert _stage(IPHONE, history) != ""
    assert _stage(IPHONE, history) == ""

    compacted = [{"role": "user", "content": "[summary of earlier turns]"}, {"role": "assistant", "content": "ok"}]
    assert _stage(IPHONE, compacted) != ""
    assert _stage(IPHONE, compacted) == ""
    assert _stage(DESKTOP, compacted) != ""
    assert _stage(DESKTOP, compacted) == ""


def test_baseline_is_the_stored_prompt_platform_on_the_same_host_only():
    assert _stage(DESKTOP, []) == ""
    assert _stage({**DESKTOP, "same_host": False}, []) != ""
    assert _stage({"kind": "tui", "label": "Terminal", "same_host": True}, []) != ""
    assert _stage(DESKTOP, [], prompt="Identity.\n\nPlatform: telegram") != ""
    assert _stage(DESKTOP, [], prompt="no trailer at all") != ""


def test_the_note_survives_a_multimodal_user_row_and_hostile_labels():
    history = []
    label = "Bob's (work) [Mac]\n  mini"
    assert _stage({"kind": "web", "label": label, "same_host": False}, history) != ""
    history[-2] = {"role": "user", "content": [{"type": "text", "text": "hi"},
                                               {"type": "text", "text": history[-2]["api_content"]}]}
    assert _stage({"kind": "web", "label": label, "same_host": False}, history) == ""
    announced = history[-4]["content"][1]["text"]
    assert announced.count("]") == 1 and "(work)" in announced


@pytest.mark.parametrize("origin", [
    None, "ios", [], {}, {"kind": "toaster", "label": "x", "same_host": True},
    {"kind": "ios", "label": "", "same_host": False}, {"kind": "ios", "label": "[ ]", "same_host": False},
])
def test_unusable_origins_stage_nothing(origin):
    assert _stage(origin, []) == ""


@pytest.mark.parametrize("attrs", [{"provider": "moa"}, {"api_mode": "codex_app_server"}])
def test_modes_that_cannot_read_the_note_back_never_stage_it(attrs):
    agent = SimpleNamespace(session_id="s", provider="openrouter", api_mode="chat_completions",
                            _client_origin=IPHONE)
    vars(agent).update(attrs)
    assert stage_origin_note(agent, STORED_PROMPT, []) is False and consume_origin_note(agent) == ""


def test_the_origin_is_consumed_so_a_reused_agent_never_replays_it():
    agent = SimpleNamespace(session_id="s", provider="openrouter", api_mode="chat_completions",
                            _client_origin=IPHONE)
    assert stage_origin_note(agent, STORED_PROMPT, []) is True
    assert agent._client_origin is None
    consume_origin_note(agent)
    assert stage_origin_note(agent, STORED_PROMPT, []) is False
