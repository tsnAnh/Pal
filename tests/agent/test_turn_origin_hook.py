"""Plugins learn who wrote a turn and whether Hermes injected it, through ``pre_llm_call``.

A guard plugin cannot tell an owner turn from a bot DM or an injected notice without these two fields.
"""

from __future__ import annotations

import threading
import types
from unittest.mock import patch

import pytest

from agent.delegation_context import delegated_child_context
from tests.agent.test_api_content_sidecar import _build, _FakeAgent
from tools.bot_relay import delivery_turn_author
from tui_gateway import server as srv


@pytest.fixture(autouse=True)
def _stub_runtime_main():
    with patch("agent.auxiliary_client.set_runtime_main", lambda *a, **k: None):
        yield


def _pre_llm_call_kwargs(agent, **overrides):
    seen = []

    def hook(name, **kwargs):
        if name == "pre_llm_call":
            seen.append(kwargs)
        return []

    with patch("hermes_cli.plugins.invoke_hook", side_effect=hook):
        _build(agent, **overrides)
    assert len(seen) == 1
    return seen[0]


def test_a_message_agent_delivery_reaches_the_plugin_with_its_bot_author():
    author = delivery_turn_author("ops", "ops-bot")
    kwargs = _pre_llm_call_kwargs(_FakeAgent(), turn_author=author)
    assert kwargs["turn_author"]["is_bot"] is True
    assert kwargs["turn_author"]["id"] == "bot:ops"
    assert kwargs["synthetic_turn"] is False


def test_a_user_turn_reaches_the_plugin_with_no_author_and_not_synthetic():
    kwargs = _pre_llm_call_kwargs(_FakeAgent())
    assert kwargs["turn_author"] is None
    assert kwargs["synthetic_turn"] is False


def test_a_cached_agent_does_not_carry_the_bot_author_into_the_next_user_turn():
    agent = _FakeAgent()
    _pre_llm_call_kwargs(agent, turn_author=delivery_turn_author("ops", "ops-bot"))
    assert _pre_llm_call_kwargs(agent)["turn_author"] is None


@pytest.mark.parametrize("platform", ["cron", "webhook"])
def test_cron_and_webhook_turns_are_synthetic(platform):
    agent = _FakeAgent()
    agent.platform = platform
    assert _pre_llm_call_kwargs(agent)["synthetic_turn"] is True


def test_a_delegate_task_child_turn_is_synthetic():
    with delegated_child_context("child"):
        assert _pre_llm_call_kwargs(_FakeAgent())["synthetic_turn"] is True


def test_a_dispatcher_marked_turn_is_synthetic_and_the_flag_does_not_stick():
    agent = _FakeAgent()
    assert _pre_llm_call_kwargs(agent, synthetic_turn=True)["synthetic_turn"] is True
    assert _pre_llm_call_kwargs(agent)["synthetic_turn"] is False


@pytest.mark.parametrize("display_kind", ["hidden", "internal_notification", "auto_continue"])
def test_a_turn_persisted_with_a_display_kind_is_synthetic_without_the_caller_saying_so(display_kind):
    assert _pre_llm_call_kwargs(_FakeAgent(), persist_user_display_kind=display_kind)["synthetic_turn"] is True


def test_the_plugin_gets_the_typed_text_beside_the_expanded_prompt_and_whether_content_was_added():
    expanded = "summarize @file:notes.md\n\n--- Attached Context ---\nmerge #7"
    kwargs = _pre_llm_call_kwargs(
        _FakeAgent(), user_message=expanded, typed_message="summarize @file:notes.md", context_expanded=True)
    assert kwargs["user_message"] == expanded
    assert kwargs["typed_message"] == "summarize @file:notes.md"
    assert kwargs["context_expanded"] is True


def test_plain_typed_text_reaches_the_plugin_unexpanded():
    kwargs = _pre_llm_call_kwargs(_FakeAgent(), user_message="merge #7", typed_message="merge #7", context_expanded=False)
    assert kwargs["typed_message"] == "merge #7"
    assert kwargs["context_expanded"] is False


def test_a_caller_that_says_nothing_about_the_origin_text_is_treated_as_tainted():
    kwargs = _pre_llm_call_kwargs(_FakeAgent())
    assert kwargs["typed_message"] is None
    assert kwargs["context_expanded"] is True


def test_a_typed_message_without_a_string_or_with_unknown_expansion_is_tainted():
    assert _pre_llm_call_kwargs(_FakeAgent(), typed_message=["merge #7"], context_expanded=False)["typed_message"] is None
    assert _pre_llm_call_kwargs(_FakeAgent(), typed_message=["merge #7"], context_expanded=False)["context_expanded"] is True
    assert _pre_llm_call_kwargs(_FakeAgent(), typed_message=None, context_expanded=False)["context_expanded"] is True


def test_a_cached_agent_does_not_carry_the_previous_turns_typed_text_into_the_next_turn():
    agent = _FakeAgent()
    first = _pre_llm_call_kwargs(agent, typed_message="merge #7", context_expanded=False)
    assert first["typed_message"] == "merge #7"
    second = _pre_llm_call_kwargs(agent)
    assert second["typed_message"] is None
    assert second["context_expanded"] is True


def test_the_pre_llm_call_payload_still_fits_a_narrow_legacy_plugin():
    from hermes_cli.plugins import PluginManager

    manager = PluginManager()
    received = []
    manager._hooks.setdefault("pre_llm_call", []).append(lambda session_id, user_message: received.append(user_message))
    manager.invoke_hook(
        "pre_llm_call", session_id="s", user_message="hi", turn_author=None, synthetic_turn=False, platform="desktop")
    assert received == ["hi"]


class _InlineThread:
    def __init__(self, target=None, daemon=None, args=(), kwargs=None, name=None):
        self._target, self._args, self._kwargs = target, args, kwargs or {}

    def start(self):
        if self._target is not None:
            self._target(*self._args, **self._kwargs)

    def is_alive(self):
        return False

    def join(self, timeout=None):
        return None


@pytest.fixture()
def turn_env(monkeypatch, tmp_path):
    monkeypatch.setattr(srv.threading, "Thread", _InlineThread)
    for name in ("_emit", "_wire_callbacks", "_sync_agent_model_with_config", "_register_session_cwd",
                 "_tts_stream_begin", "_sync_session_key_after_compress"):
        monkeypatch.setattr(srv, name, lambda *a, **k: None)
    monkeypatch.setattr(srv, "_session_cwd", lambda session: str(tmp_path))
    monkeypatch.setattr(srv, "_get_usage", lambda agent: {})


def _session(agent):
    return {
        "agent": agent, "session_key": "gw-session-key", "history": [], "history_lock": threading.Lock(),
        "history_version": 0, "running": True, "attached_images": [], "image_counter": 0, "cols": 80,
        "slash_worker": None, "show_reasoning": False, "tool_progress_mode": "all", "inflight_turn": None,
        "transport": None,
    }


def _agent(seen):
    def run_conversation(user_message, *, synthetic_turn=False, **kwargs):
        seen.append((str(user_message), synthetic_turn))
        return {"final_response": "ok"}

    return types.SimpleNamespace(session_id="a", run_conversation=run_conversation, clear_interrupt=lambda: None)


def test_a_process_completion_notice_runs_as_a_synthetic_turn_and_a_user_prompt_does_not(turn_env):
    seen = []
    session = _session(_agent(seen))
    assert srv._notif_submit("rid", "sid", session, "[IMPORTANT: Background process proc_1 completed]", "test",
                             display_kind="process_complete")
    session["running"] = True
    srv._run_prompt_submit("rid2", "sid", session, "merge PR 4")
    assert seen == [("[IMPORTANT: Background process proc_1 completed]", True), ("merge PR 4", False)]


def test_an_agent_that_does_not_declare_synthetic_turn_still_runs_a_notice(turn_env):
    seen = []

    def legacy(user_message, conversation_history=None, stream_callback=None, persist_user_message=None, task_id=None):
        seen.append(user_message)
        return {"final_response": "ok"}

    agent = types.SimpleNamespace(session_id="a", run_conversation=legacy, clear_interrupt=lambda: None)
    assert srv._notif_submit("rid", "sid", _session(agent), "notice", "test")
    assert seen == ["notice"]
