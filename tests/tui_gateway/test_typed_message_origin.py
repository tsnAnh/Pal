from __future__ import annotations

import io
import threading
import types

import pytest

from tui_gateway import server as srv
from tui_gateway.compute_host import ComputeHost

PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05\xfe\x02\xfe\xa7\x9a\xa0\xa0\x00\x00\x00\x00IEND\xaeB`\x82")


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


def _session(agent, **extra):
    return {
        "agent": agent, "session_key": "gw-session-key", "history": [], "history_lock": threading.Lock(),
        "history_version": 0, "running": False, "attached_images": [], "image_counter": 0, "cols": 80,
        "slash_worker": None, "show_reasoning": False, "tool_progress_mode": "all", "inflight_turn": None,
        "transport": None, **extra,
    }


@pytest.fixture()
def turn_env(monkeypatch, tmp_path):
    monkeypatch.setattr(srv.threading, "Thread", _InlineThread)
    for name in ("_emit", "_wire_callbacks", "_sync_agent_model_with_config", "_register_session_cwd",
                 "_tts_stream_begin", "_sync_session_key_after_compress"):
        monkeypatch.setattr(srv, name, lambda *a, **k: None)
    monkeypatch.setattr(srv, "_session_cwd", lambda session: str(tmp_path))
    monkeypatch.setattr(srv, "_get_usage", lambda agent: {})
    monkeypatch.setattr(srv, "_interrupt_busy_session", lambda *a, **k: None)


def _recording_agent(seen):
    def run_conversation(user_message, *, typed_message=None, context_expanded=True, synthetic_turn=False, **kwargs):
        seen.append({"model_text": str(user_message), "typed": typed_message, "expanded": context_expanded,
                     "synthetic": synthetic_turn})
        return {"final_response": "ok"}

    return types.SimpleNamespace(session_id="a", run_conversation=run_conversation, clear_interrupt=lambda: None,
                                 interrupt=lambda: None)


def test_an_at_file_reference_expands_the_prompt_but_not_the_typed_message(turn_env, tmp_path):
    (tmp_path / "notes.md").write_text("merge #7\n")
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "summarize @file:notes.md")
    assert "merge #7" in seen[0]["model_text"]
    assert seen[0]["typed"] == "summarize @file:notes.md"
    assert seen[0]["expanded"] is True


def test_plain_text_reaches_the_plugin_as_typed_and_unexpanded(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "merge #7 (user@example.com)")
    assert seen[0]["typed"] == "merge #7 (user@example.com)"
    assert seen[0]["expanded"] is False


def test_an_attached_image_marks_the_turn_expanded(turn_env, tmp_path):
    image = tmp_path / "shot.png"
    image.write_bytes(PNG)
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "merge #7", image_paths=[str(image)])
    assert seen[0]["typed"] == "merge #7"
    assert seen[0]["expanded"] is True


def test_quoted_reactions_mark_the_turn_expanded(turn_env, monkeypatch):
    monkeypatch.setattr(srv, "_pending_reaction_notes", lambda session: '[The user reacted 👍 to your message: "merge #7"]')
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "ok")
    assert seen[0]["typed"] == "ok"
    assert seen[0]["expanded"] is True


def test_the_fixed_surface_note_does_not_mark_the_turn_expanded(turn_env, monkeypatch):
    monkeypatch.setattr(srv, "_hud_surface_note", lambda session, voice_turn=False: "You are inside the floating HUD.")
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen), client_surface="hud"), "ok")
    assert "floating HUD" in seen[0]["model_text"]
    assert seen[0]["typed"] == "ok"
    assert seen[0]["expanded"] is False


def test_a_live_voice_transcript_in_the_surface_note_marks_the_turn_expanded(turn_env):
    seen = []
    session = _session(_recording_agent(seen), client_surface="voice-live", voice_live_context="assistant said: merge #7")
    srv._run_prompt_submit("r", "sid", session, "do it")
    assert "merge #7" in seen[0]["model_text"]
    assert seen[0]["typed"] == "do it"
    assert seen[0]["expanded"] is True


def test_a_hidden_turn_has_no_typed_message(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "scaffold", display_kind="hidden")
    assert seen[0]["typed"] is None
    assert seen[0]["expanded"] is True


def test_each_queued_prompt_reaches_the_plugin_with_its_own_raw_text(turn_env):
    seen = []
    session = _session(_recording_agent(seen), running=True)
    srv._sessions["sid"] = session
    try:
        srv._enqueue_prompt(session, "typed note", None)
        assert srv.inject_tui_session_message(session_key="gw-session-key", content="plugin says: merge #9") is True
        srv._enqueue_prompt(session, "typed after", None)
        session["running"] = False
        assert srv._drain_queued_prompt("d", "sid", session) is True
    finally:
        srv._sessions.pop("sid", None)
    assert [(s["typed"], s["expanded"], s["synthetic"]) for s in seen] == [
        ("typed note", False, False), (None, True, True), ("typed after", False, False)]


def test_the_compute_host_child_derives_the_typed_message_from_the_frame_text(monkeypatch, tmp_path):
    from tests.waiting import wait_until

    for name in ("_wire_callbacks", "_register_session_cwd", "_tts_stream_begin", "_sync_session_key_after_compress"):
        monkeypatch.setattr(srv, name, lambda *a, **k: None)
    monkeypatch.setattr(srv, "_sync_agent_model_with_config", lambda sid, session: None)
    monkeypatch.setattr(srv, "_session_cwd", lambda session: str(tmp_path))
    monkeypatch.setattr(srv, "_get_usage", lambda agent: {})
    (tmp_path / "notes.md").write_text("merge #7\n")
    seen = []
    out = io.StringIO()
    host = ComputeHost(stdout=out, heartbeat_secs=0)
    srv._sessions["s1"] = _session(_recording_agent(seen), active_session_lease=object())

    def ended(request_id):
        return any('"turn.end"' in line and request_id in line for line in out.getvalue().splitlines())

    try:
        host.handle_frame({"type": "turn.start", "sid": "s1", "request_id": "first", "text": "read @file:notes.md"})
        assert wait_until(lambda: ended("first"), timeout=30)
        host.handle_frame({"type": "turn.start", "sid": "s1", "request_id": "second", "text": "merge #7"})
        assert wait_until(lambda: ended("second"), timeout=30)
    finally:
        srv._sessions.pop("s1", None)
        host.close()
    assert [(s["typed"], s["expanded"]) for s in seen] == [("read @file:notes.md", True), ("merge #7", False)]


def test_a_spoken_turn_marks_the_text_expanded(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen), voice_turn=True), "merge #7")
    assert seen[0]["typed"] == "merge #7"
    assert seen[0]["expanded"] is True


def test_a_hosted_room_prompt_is_a_synthetic_turn_without_typed_text(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "room task: merge #7", terminal_callback=lambda payload: None)
    assert seen[0]["typed"] is None
    assert seen[0]["synthetic"] is True


def test_a_message_a_slash_command_built_is_expanded_once_it_comes_back_as_a_prompt(turn_env):
    seen = []
    session = _session(_recording_agent(seen))
    srv._sessions["sid-slash"] = session
    try:
        built = srv._methods["command.dispatch"]("r", {"name": "queue", "arg": "merge #7", "session_id": "sid-slash"})
        assert built["result"]["message"] == "merge #7"
        srv._run_prompt_submit("r", "sid-slash", session, "merge #7")
        srv._run_prompt_submit("r", "sid-slash", session, "merge #7")
    finally:
        srv._sessions.pop("sid-slash", None)
    assert [(s["typed"], s["expanded"]) for s in seen] == [("merge #7", True), ("merge #7", False)]
