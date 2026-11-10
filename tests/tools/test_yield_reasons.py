"""A foreground tool yields for a reason: the owner wrote mid-command, or the turn's background
budget ran out. The yielded command keeps running, and the note the model reads differs by reason."""
import json
import threading
import time

import psutil
import pytest

from tools import interrupt as interrupt_mod
from tools.interrupt import YieldReason
from tools.process_registry import process_registry
from tools.terminal_tool import terminal_tool
from tests.waiting import wait_until

pytestmark = pytest.mark.platforms("posix")


def test_the_stronger_yield_reason_wins_whatever_order_they_arrive_in():
    tid = threading.current_thread().ident
    try:
        interrupt_mod.request_yield(tid, YieldReason.BUDGET)
        interrupt_mod.request_yield(tid, YieldReason.OWNER_MESSAGE)
        interrupt_mod.request_yield(tid, YieldReason.BUDGET)
        assert interrupt_mod.take_yield(tid) is YieldReason.OWNER_MESSAGE
        assert interrupt_mod.take_yield(tid) is None
        interrupt_mod.request_yield(tid, YieldReason.BUDGET)
        assert interrupt_mod.take_yield(tid) is YieldReason.BUDGET
    finally:
        interrupt_mod.take_yield(tid)


def _run_terminal_until_yielded(reason, tmp_path, monkeypatch, task_id):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    done, result = threading.Event(), {}

    def worker():
        result["tid"] = threading.current_thread().ident
        started = time.monotonic()
        result["json"] = json.loads(terminal_tool("echo started; sleep 60; echo done", task_id=task_id, timeout=90))
        result["elapsed"] = time.monotonic() - started
        done.set()

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    wait_until(lambda: "tid" in result and _command_running(), timeout=30, what="the foreground command to start")
    interrupt_mod.request_yield(result["tid"], reason)
    assert done.wait(15), "terminal kept blocking after the yield request"
    return result


def _command_running():
    for child in psutil.Process().children(recursive=True):
        try:
            if "sleep 60" in " ".join(child.cmdline()):
                return True
        except psutil.Error:
            continue
    return False


@pytest.mark.live_system_guard_bypass
@pytest.mark.parametrize("reason, told", [
    (YieldReason.BUDGET, "one plain sentence that the work continues in the background"),
    (YieldReason.OWNER_MESSAGE, "Answer the owner now"),
])
def test_a_yielded_command_keeps_running_and_the_note_names_what_the_model_should_do(
        reason, told, tmp_path, monkeypatch):
    result = _run_terminal_until_yielded(reason, tmp_path, monkeypatch, f"yield-{reason.value}")
    out = result["json"]
    try:
        assert out["status"] == "yielded_to_background" and out["exit_code"] is None
        assert out["notify_on_complete"] is True
        assert told in out["note"]
        assert result["elapsed"] < 15
        assert process_registry.poll(out["session_id"])["status"] == "running"
        assert psutil.pid_exists(out["pid"])
        assert not interrupt_mod.is_thread_yield_requested(result["tid"])
    finally:
        process_registry.kill_process(out["session_id"])


@pytest.mark.live_system_guard_bypass
def test_a_wait_on_a_background_process_stops_waiting_when_the_turn_yields(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    started = json.loads(terminal_tool("sleep 60", task_id="wait-yield", background=True, notify_on_complete=True))
    session_id, result, done = started["session_id"], {}, threading.Event()

    def waiter():
        result["tid"] = threading.current_thread().ident
        result["wait"] = process_registry.wait(session_id, timeout=120)
        done.set()

    thread = threading.Thread(target=waiter, daemon=True)
    thread.start()
    try:
        wait_until(lambda: "tid" in result, timeout=15, what="the wait to begin")
        interrupt_mod.request_yield(result["tid"], YieldReason.BUDGET)
        assert done.wait(15), "the wait kept blocking after the yield request"
        out = result["wait"]
        assert out["status"] == "interrupted" and out["process_running"] is True
        assert "one plain sentence that the work continues in the background" in out["note"]
        assert process_registry.poll(session_id)["status"] == "running"
    finally:
        process_registry.kill_process(session_id)
