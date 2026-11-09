from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest

from tests.e2e.core.bots._creation import CREATE_COMMANDS, CREATE_IDS, LAUNCH_MODEL, launch_world
from tests.e2e.core.bots._world import World
from tests.e2e.core.history._helpers import InProcessSession
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall

APPROVALS_OFF = {"approvals": {"mode": "off"}}


class Human:
    def __init__(self, verdict: str) -> None:
        self.verdict = verdict
        self.asked: list[str] = []

    def __call__(self, command: str, description: str, *, allow_permanent: bool = True,
                 allow_session: bool = True, smart_denied: bool = False) -> str:
        self.asked.append(command)
        return self.verdict


@pytest.fixture
def attached(tmp_path: Path, monkeypatch):
    from tools.terminal_tool import set_approval_callback

    servers: list[FakeLLMServer] = []

    def make(extra: dict[str, Any] | None = None, *, session_yolo: bool = False):
        srv = FakeLLMServer()
        srv.start()
        servers.append(srv)
        w = launch_world(tmp_path, srv.base_url, extra)
        w.catalog_skill("catalog-one", enabled_for=["default"])
        w.catalog_skill("catalog-two", enabled_for=["default"])
        w.save_catalog_mcp({"shared-docs": {"url": "http://127.0.0.1:9/mcp"}})
        w.update_config("default", {"mcp_servers": {"shared-docs": {"enabled": True}}})
        monkeypatch.setenv("HOME", str(w.home))
        monkeypatch.setenv("HERMES_HOME", str(w.default))
        monkeypatch.setenv("PATH", f"{w.shim_dir}:{os.environ['PATH']}")
        monkeypatch.setenv("HERMES_INTERACTIVE", "1")
        monkeypatch.setenv("HERMES_SESSION_KEY", "e2e-bot-session")
        monkeypatch.setenv("HERMES_STATE_DB_GUARD_BYPASS", "1")
        monkeypatch.chdir(w.workdir)
        if session_yolo:
            from tools.approval import enable_session_yolo
            enable_session_yolo("e2e-bot-session")
        return w, srv

    yield make
    set_approval_callback(None)
    from tools.terminal_tool import cleanup_all_environments
    cleanup_all_environments()
    for srv in servers:
        srv.stop()
    try:
        from tools.approval import disable_session_yolo
        disable_session_yolo("e2e-bot-session")
    except Exception:
        pass


def run_attached_turn(w: World, srv: FakeLLMServer, command: str, human: Human) -> None:
    from tools.terminal_tool import set_approval_callback

    srv.push(ToolCall("terminal", {"command": command}), Text("done"))
    set_approval_callback(human)
    session = InProcessSession(srv.base_url, w.default, "e2e-bot-session")
    session.turn("please run the maintenance step")
    session.db.close()


def test_the_approval_seam_reaches_a_human_for_an_ordinary_dangerous_command(attached) -> None:
    w, srv = attached()
    victim = w.workdir / "victim-dir"
    victim.mkdir()
    (victim / "f.txt").write_text("x", encoding="utf-8")
    human = Human("deny")
    run_attached_turn(w, srv, f"rm -rf {victim}", human)
    assert human.asked and "rm -rf" in human.asked[0]
    assert victim.exists()


def test_a_bot_is_created_with_the_launching_profiles_model_and_nothing_else_when_a_human_approves(attached) -> None:
    w, srv = attached()
    human = Human("once")
    run_attached_turn(w, srv, "hermes bot create evo --display-name 'Evo Bot'", human)

    assert any("bot create evo" in c for c in human.asked), f"no human was asked: {human.asked}"
    assert w.profile_exists("evo")
    cfg = w.config("evo")
    assert cfg["model"]["default"] == LAUNCH_MODEL
    assert {"catalog-one", "catalog-two"} <= set(cfg.get("skills", {}).get("disabled", []))
    assert w.visible_markers("evo") == set()
    assert "MARK_CATALOG_ONE" in w.visible_markers("default")
    servers = cfg.get("mcp_servers") or {}
    assert not any((entry or {}).get("enabled", True) for entry in servers.values()), servers
    memory_files = [p for p in (w.home_of("evo") / "memories").rglob("*") if p.is_file()]
    assert all("launch-profile-private-fact" not in p.read_text(encoding="utf-8") for p in memory_files)
    assert all(p.read_text(encoding="utf-8").strip() == "" for p in memory_files)


def test_a_bot_created_from_a_chat_runs_the_model_that_chat_runs_rather_than_the_config_default(attached) -> None:
    from hermes_state import SessionDB

    w, srv = attached()
    live_route = {"provider": "openai-codex", "base_url": "https://chatgpt.com/backend-api/codex",
                  "api_mode": "codex_responses"}
    db = SessionDB(db_path=w.default / "state.db")
    db.create_session("e2e-bot-session", "desktop", model="gpt-live-e2e",
                      model_config={"model": "gpt-live-e2e", **live_route, "follow_profile_config": True})
    db.close()

    run_attached_turn(w, srv, "hermes bot create evo", Human("once"))

    assert w.profile_exists("evo")
    model = w.config("evo")["model"]
    assert {key: model.get(key) for key in ("default", *live_route)} == {"default": "gpt-live-e2e", **live_route}


@pytest.mark.parametrize("command", CREATE_COMMANDS + ["hermes profile delete victim --yes"],
                         ids=[*CREATE_IDS, "profile-delete"])
@pytest.mark.parametrize("mode", ["manual", "approvals-off", "session-yolo"])
def test_a_human_who_denies_stops_bot_commands_in_every_approval_mode(attached, mode: str, command: str) -> None:
    w, srv = attached(APPROVALS_OFF if mode == "approvals-off" else None, session_yolo=mode == "session-yolo")
    w.add_bot("victim")
    human = Human("deny")
    run_attached_turn(w, srv, command, human)
    assert human.asked, f"{mode}: `{command}` ran without asking a human"
    assert not w.profile_exists("evil")
    assert w.profile_exists("victim")
