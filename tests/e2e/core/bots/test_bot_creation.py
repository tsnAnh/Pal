from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest

from hermes_cli.profile_admin_guard import CREATE_REFUSED_MESSAGE
from tests.e2e.core.bots._creation import CREATE_COMMANDS, CREATE_IDS, launch_world
from tests.e2e.core.bots._world import World
from tests.e2e.core.history._helpers import InProcessSession
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall

APPROVALS_OFF = {"approvals": {"mode": "off"}}
STORED_MODES = {"manual": {"approvals": {"mode": "manual"}}, "smart": {"approvals": {"mode": "smart"}},
                "off": APPROVALS_OFF}


class Human:
    def __init__(self) -> None:
        self.asked: list[str] = []

    def __call__(self, command: str, description: str, **_kwargs: Any) -> str:
        self.asked.append(command)
        return "deny"


@pytest.fixture
def attached(tmp_path: Path, monkeypatch):
    from tools.terminal_tool import set_approval_callback

    servers: list[FakeLLMServer] = []

    def make(extra: dict[str, Any] | None = None):
        srv = FakeLLMServer()
        srv.start()
        servers.append(srv)
        w = launch_world(tmp_path, srv.base_url, extra)
        monkeypatch.setenv("HOME", str(w.home))
        monkeypatch.setenv("HERMES_HOME", str(w.default))
        monkeypatch.setenv("PATH", f"{w.shim_dir}:{os.environ['PATH']}")
        monkeypatch.setenv("HERMES_INTERACTIVE", "1")
        monkeypatch.setenv("HERMES_SESSION_KEY", "e2e-bot-session")
        monkeypatch.setenv("HERMES_STATE_DB_GUARD_BYPASS", "1")
        monkeypatch.chdir(w.workdir)
        return w, srv

    yield make
    set_approval_callback(None)
    from tools.terminal_tool import cleanup_all_environments
    cleanup_all_environments()
    for srv in servers:
        srv.stop()


def run_attached_turn(w: World, srv: FakeLLMServer, command: str, human: Human) -> list[str]:
    from tools.terminal_tool import set_approval_callback

    srv.push(ToolCall("terminal", {"command": command}), Text("done"))
    set_approval_callback(human)
    session = InProcessSession(srv.base_url, w.default, "e2e-bot-session")
    result = session.turn("please run the maintenance step")
    session.db.close()
    return [str(m.get("content")) for m in result["messages"] if m.get("role") == "tool"]


@pytest.mark.parametrize("mode", list(STORED_MODES))
def test_a_dangerous_command_runs_without_asking_whatever_mode_the_profile_stored(attached, mode: str) -> None:
    w, srv = attached(STORED_MODES[mode])
    victim = w.workdir / "victim-dir"
    victim.mkdir()
    (victim / "f.txt").write_text("x", encoding="utf-8")
    human = Human()
    run_attached_turn(w, srv, f"rm -rf {victim}", human)
    assert human.asked == []
    assert not victim.exists()


@pytest.mark.parametrize("command", CREATE_COMMANDS + ["hermes bot create evo --display-name 'Evo Bot'"],
                         ids=[*CREATE_IDS, "bot-create-named"])
@pytest.mark.parametrize("mode", list(STORED_MODES))
def test_an_agent_cannot_create_a_bot_in_any_mode_and_no_human_is_asked(attached, mode: str, command: str) -> None:
    w, srv = attached(STORED_MODES[mode])
    human = Human()
    tool_results = run_attached_turn(w, srv, command, human)
    assert human.asked == []
    assert any(CREATE_REFUSED_MESSAGE in content for content in tool_results), tool_results
    assert not w.profile_exists("evil") and not w.profile_exists("evo")


def test_a_profile_delete_runs_without_asking(attached) -> None:
    w, srv = attached()
    w.add_bot("victim")
    human = Human()
    run_attached_turn(w, srv, "hermes profile delete victim --yes", human)
    assert human.asked == []
    assert not w.profile_exists("victim")
