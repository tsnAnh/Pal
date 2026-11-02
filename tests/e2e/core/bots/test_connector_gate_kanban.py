from __future__ import annotations

import json

import psutil
import pytest

from tests.e2e.core.bots._gate import build
from tests.e2e.core.bots._world import World, marker_for
from tests.e2e.core.kanban._helpers import Board
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall
from tests.waiting import wait_until


def worker_exited(pid: int) -> bool:
    if not psutil.pid_exists(pid):
        return True
    return psutil.Process(pid).status() == psutil.STATUS_ZOMBIE


@pytest.mark.live_system_guard_bypass
def test_kanban_worker_skill_pin_is_denied_when_not_connected(tmp_path) -> None:
    results = {}
    with FakeLLMServer(lambda rec: Text("done") if rec["body"]["messages"][-1].get("role") == "tool"
                       else ToolCall("kanban_complete", {"summary": "ran"})) as srv:
        board = Board(tmp_path, srv.base_url)
        try:
            w = World(tmp_path, srv.base_url, adopt_default=True)
            build(w, "shared", bots=("a", "b"))
            for bot in ("a", "b"):
                tid = board.cli_json("create", f"card for {bot}", "--assignee", bot, "--skill", "gated-mcp")["id"]
                board.dispatch()
                pid = board.task(tid)["worker_pid"]
                assert pid, board.diag(tid)
                wait_until(lambda: worker_exited(int(pid)), timeout=60, what=f"worker of {bot}'s card to exit")
                results[bot] = json.dumps([
                    r["messages"] for r in srv.main_requests() if tid in json.dumps(r["messages"])])
        finally:
            board.kill_workers()
    marker = marker_for("gated-mcp")
    assert marker in results["a"], "connected bot's pinned skill never reached its worker"
    assert marker not in results["b"], "kanban worker for an unconnected bot got the gated skill"


