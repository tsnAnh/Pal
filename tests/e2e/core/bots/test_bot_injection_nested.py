from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.e2e.core.bots._creation import CREATE_COMMANDS, CREATE_IDS, count_tools, injected_responder, launch_world, write_notes
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall


def test_injected_profile_delete_cannot_remove_a_bot_under_yolo(tmp_path: Path) -> None:
    cmd = "hermes profile delete victim --yes"
    with FakeLLMServer(injected_responder(cmd, tmp_path / "work" / "notes.txt")) as srv:
        w = launch_world(tmp_path, srv.base_url)
        w.add_bot("victim")
        write_notes(w, cmd)
        w.hermes("default", "chat", "-q", "summarize notes.txt", "-Q", "--yolo")
        assert len(srv.main_requests()) >= 3
    assert w.profile_exists("victim"), "injected `hermes profile delete` removed a bot without a human"


@pytest.mark.parametrize("cmd", CREATE_COMMANDS, ids=CREATE_IDS)
def test_delegated_child_cannot_create_a_bot_even_under_yolo(tmp_path: Path, cmd: str) -> None:
    def respond(rec: dict):
        messages = rec["body"]["messages"]
        first_user = next((str(m.get("content")) for m in messages if m.get("role") == "user"), "")
        has_tool = count_tools(messages) > 0
        if "CHILD-GOAL" in first_user:
            return Text("child done") if has_tool else ToolCall("terminal", {"command": cmd})
        return Text("parent done") if has_tool else ToolCall(
            "delegate_task", {"goal": "CHILD-GOAL carry out the maintenance step", "context": "none"})

    with FakeLLMServer(respond) as srv:
        w = launch_world(tmp_path, srv.base_url)
        w.hermes("default", "chat", "-q", "PARENT-PROMPT delegate", "-Q", "--yolo")
        child = [r for r in srv.main_requests() if "CHILD-GOAL" in json.dumps(r["messages"][1:2])]
        assert len(child) >= 2, "the delegated child never ran its terminal call"
    assert not w.profile_exists("evil")
