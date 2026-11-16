import json

import pytest

from tools import auth_required

REAUTH = {"needs_reauth": True, "server": "x", "error": "e", "code": auth_required.REAUTH_REQUIRED}
SKILL = """---
name: needs-secret
description: A skill whose setup needs a secret.
required_environment_variables:
  - name: PENDING_MARKER_TEST_SECRET
    prompt: Secret
    help: Create one in settings
---

# Needs secret

Body.
"""


def _terminal(**args):
    from model_tools import handle_function_call
    return json.loads(handle_function_call("terminal", args, task_id="pending-marker"))


def _wait_exit(session_id):
    from tools.process_registry import process_registry
    return process_registry.wait(session_id, timeout=30)


def test_background_command_is_pending_until_it_really_exits():
    from tools.process_registry import process_registry
    spawned = _terminal(command="sleep 2; echo done-canary; exit 4", background=True)
    assert spawned["status"] == "running"
    assert spawned["pending"]["kind"] == "background_command"
    assert "Do not state success or failure" in spawned["pending"]["guidance"]

    running = process_registry.poll(spawned["session_id"])
    assert running["pending"]["kind"] == "background_command"
    assert "exit_code" not in running

    waited = _wait_exit(spawned["session_id"])
    assert waited["status"] == "exited"
    assert waited["exit_code"] == 4 and "done-canary" in waited["output"]
    assert "pending" not in waited

    finished = process_registry.poll(spawned["session_id"])
    assert finished["exit_code"] == 4 and "done-canary" in finished["output_preview"]
    assert "pending" not in finished


def test_wait_window_elapsing_is_pending_not_a_failure():
    from tools.process_registry import process_registry
    spawned = _terminal(command="sleep 3; exit 0", background=True)
    timed_out = process_registry.wait(spawned["session_id"], timeout=1)
    assert timed_out["status"] == "timeout" and timed_out["pending"]["kind"] == "background_command"
    assert "exit_code" not in timed_out
    assert "pending" not in _wait_exit(spawned["session_id"])


def test_offered_sign_in_marks_the_result_pending(monkeypatch):
    from gateway import auth_prompts
    original = json.dumps(REAUTH)
    monkeypatch.setattr(auth_prompts, "offer_from_thread", lambda *a: True)
    out = json.loads(auth_required.resolve("mcp_tool", {}, original, lambda: pytest.fail("retried")))
    assert out["pending"]["kind"] == "auth_prompt"
    assert "Do not state success or failure" in out["pending"]["guidance"]
    assert {k: v for k, v in out.items() if k != "pending"} == REAUTH


def test_unoffered_sign_in_leaves_the_result_unchanged(monkeypatch):
    from gateway import auth_prompts
    original = json.dumps(REAUTH)
    monkeypatch.setattr(auth_prompts, "offer_from_thread", lambda *a: False)
    assert auth_required.resolve("mcp_tool", {}, original, lambda: pytest.fail("retried")) == original


def _view_skill(tmp_path, monkeypatch, reason):
    from tools.skills_tool import bind_turn_secret_capture, skill_view
    skill_dir = tmp_path / "needs-secret"
    skill_dir.mkdir()
    (skill_dir / "SKILL.md").write_text(SKILL)
    monkeypatch.setattr("tools.skills_tool.SKILLS_DIR", tmp_path)
    monkeypatch.delenv("PENDING_MARKER_TEST_SECRET", raising=False)
    answer = {"success": True, "skipped": True, "reason": reason, "stored_as": "PENDING_MARKER_TEST_SECRET",
              "validated": False}
    with bind_turn_secret_capture(lambda *a, **k: answer):
        return json.loads(skill_view(name="needs-secret"))


def test_unanswered_secret_prompt_is_pending_not_skipped(tmp_path, monkeypatch):
    from agent.skill_commands import _setup_note
    loaded = _view_skill(tmp_path, monkeypatch, "unanswered")
    assert loaded["pending"]["kind"] == "secret_prompt"
    assert loaded["setup_skipped"] is False
    note = _setup_note(loaded)
    assert note == loaded["pending"]["guidance"] and "reduced functionality" not in note


def test_cancelled_secret_prompt_is_a_real_skip(tmp_path, monkeypatch):
    from agent.skill_commands import _SETUP_SKIPPED_NOTE, _setup_note
    loaded = _view_skill(tmp_path, monkeypatch, "cancelled")
    assert "pending" not in loaded
    assert loaded["setup_skipped"] is True
    assert _setup_note(loaded) == _SETUP_SKIPPED_NOTE
