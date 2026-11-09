import io
import threading
import types

import pytest

from tui_gateway import server as srv
from tui_gateway.compute_host import ComputeHost

NOTE = '[@mentions resolved from the Bot Mode roster: @faker-kit = agent profile "faker-kit"]'
PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05\xfe\x02\xfe\xa7\x9a\xa0\xa0\x00\x00\x00\x00IEND\xaeB`\x82")


def _session(agent, **extra):
    return {
        "agent": agent, "session_key": "gw-session-key", "history": [], "history_lock": threading.Lock(),
        "history_version": 0, "running": False, "attached_images": [], "image_counter": 0, "cols": 80,
        "slash_worker": None, "show_reasoning": False, "tool_progress_mode": "all", "inflight_turn": None,
        "transport": None, **extra,
    }


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
    monkeypatch.setattr(srv, "_interrupt_busy_session", lambda *a, **k: None)


def _recording_agent(seen):
    def run_conversation(user_message, *, persist_user_message=None, typed_message=None, context_expanded=True,
                         **kwargs):
        seen.append({"model": user_message, "persisted": persist_user_message, "typed": typed_message,
                     "expanded": context_expanded})
        return {"final_response": "ok"}

    return types.SimpleNamespace(session_id="a", run_conversation=run_conversation, clear_interrupt=lambda: None,
                                 interrupt=lambda: None, steer=lambda text: pytest.fail("a note-bearing prompt was steered"))


def test_the_note_follows_the_typed_text_for_the_model_and_the_persisted_prompt_stays_typed(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "ask @faker-kit to say hi", turn_context=NOTE)
    assert seen[0]["model"] == f"ask @faker-kit to say hi\n\n{NOTE}"
    assert seen[0]["persisted"] == "ask @faker-kit to say hi"
    assert seen[0]["typed"] == "ask @faker-kit to say hi"
    assert seen[0]["expanded"] is True


def test_a_turn_without_a_note_is_unchanged(turn_env):
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "ask @faker-kit to say hi")
    assert seen[0]["model"] == "ask @faker-kit to say hi"
    assert seen[0]["expanded"] is False


def test_an_inlined_image_turn_keeps_the_note_out_of_the_persisted_prompt(turn_env, tmp_path):
    image = tmp_path / "shot.png"
    image.write_bytes(PNG)
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "what is this @faker-kit",
                           image_paths=[str(image)], turn_context=NOTE)
    assert seen[0]["model"].endswith(f"what is this @faker-kit\n\n{NOTE}")
    assert NOTE not in seen[0]["persisted"]


def test_a_native_vision_turn_carries_the_note_as_a_wire_only_text_part(turn_env, monkeypatch, tmp_path):
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}
    monkeypatch.setattr(srv, "_route_turn_images", lambda agent, prompt, images: [{"type": "text", "text": prompt}, image])
    seen = []
    srv._run_prompt_submit("r", "sid", _session(_recording_agent(seen)), "what is this @faker-kit",
                           image_paths=[str(tmp_path / "shot.png")], turn_context=NOTE)
    assert seen[0]["model"][-1] == {"type": "text", "text": NOTE}
    assert NOTE not in str(seen[0]["persisted"])
    assert image in seen[0]["persisted"]


def test_a_queued_prompt_keeps_its_own_note_and_never_merges_into_its_neighbours(turn_env):
    seen = []
    session = _session(_recording_agent(seen), running=True)
    srv._sessions["sid"] = session
    try:
        srv._enqueue_prompt(session, "first", None)
        srv._enqueue_prompt(session, "second @faker-kit", None, turn_context=NOTE)
        srv._enqueue_prompt(session, "third", None)
        assert [e.get("turn_context") for e in [session["queued_prompt"], *session["queued_prompts"]]] == [None, NOTE, None]
        session["running"] = False
        assert srv._drain_queued_prompt("d", "sid", session) is True
    finally:
        srv._sessions.pop("sid", None)
    assert [(s["typed"], s["model"]) for s in seen] == [
        ("first", "first"), ("second @faker-kit", f"second @faker-kit\n\n{NOTE}"), ("third", "third")]


def test_a_busy_session_queues_a_note_bearing_prompt_instead_of_steering_it(turn_env, monkeypatch):
    monkeypatch.setattr(srv, "_load_busy_input_mode", lambda: "steer")
    monkeypatch.setattr(srv, "_persist_queued_user_row", lambda *a, **k: None)
    session = _session(_recording_agent([]), running=True)
    reply = srv._handle_busy_submit("r", "sid", session, "ask @faker-kit", None, turn_context=NOTE)
    assert reply["result"]["status"] == "queued"
    assert session["queued_prompt"]["turn_context"] == NOTE


def test_blank_context_is_ignored_and_an_oversized_note_is_capped():
    assert srv._submitted_turn_context({"turn_context": "  \n "}) == ""
    assert srv._submitted_turn_context({}) == ""
    assert srv._submitted_turn_context({"turn_context": f"  {NOTE}  "}) == NOTE
    assert len(srv._submitted_turn_context({"turn_context": "x" * 9000})) == 4000


def test_a_non_string_note_is_refused_at_the_contract():
    reply = srv.handle_request({"id": "p", "method": "prompt.submit", "params": {
        "session_id": "sid", "text": "hi", "turn_context": {"note": NOTE}}})
    assert reply["error"]["code"] == 4000
    assert "turn_context" in reply["error"]["message"]


def test_the_compute_host_child_runs_the_turn_with_the_frames_note(monkeypatch, tmp_path):
    from tests.waiting import wait_until

    for name in ("_wire_callbacks", "_register_session_cwd", "_tts_stream_begin", "_sync_session_key_after_compress"):
        monkeypatch.setattr(srv, name, lambda *a, **k: None)
    monkeypatch.setattr(srv, "_sync_agent_model_with_config", lambda sid, session: None)
    monkeypatch.setattr(srv, "_session_cwd", lambda session: str(tmp_path))
    monkeypatch.setattr(srv, "_get_usage", lambda agent: {})
    seen = []
    out = io.StringIO()
    host = ComputeHost(stdout=out, heartbeat_secs=0)
    srv._sessions["s1"] = _session(_recording_agent(seen), active_session_lease=object())
    try:
        host.handle_frame({"type": "turn.start", "sid": "s1", "request_id": "first",
                           "text": "ask @faker-kit", "turn_context": NOTE})
        assert wait_until(lambda: any('"turn.end"' in line for line in out.getvalue().splitlines()), timeout=30)
    finally:
        srv._sessions.pop("s1", None)
        host.close()
    assert (seen[0]["typed"], seen[0]["model"]) == ("ask @faker-kit", f"ask @faker-kit\n\n{NOTE}")


def test_the_compute_host_frame_carries_the_note_the_isolated_dispatch_was_given():
    session = _session(types.SimpleNamespace())
    frame = srv._compute_host_turn_frame("r", "sid", session, "ask @faker-kit", turn_context=NOTE)
    assert frame["turn_context"] == NOTE
    assert "turn_context" not in srv._compute_host_turn_frame("r", "sid", session, "ask")
