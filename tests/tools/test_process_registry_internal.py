"""Internal background processes (bot delivery runners) are hidden from user-facing surfaces,
stay resolvable for their owner, and stale or overdue entries clean themselves up."""

import json
import sys
from contextvars import ContextVar, copy_context
from types import SimpleNamespace

import pytest

import tools.process_registry as module
from tools import bot_mode_dm
from tools.process_registry import (
    FINISHED_LISTING_RETENTION_SECONDS,
    InternalProcessPolicy,
    ProcessRegistry,
    ProcessSession,
)
from tui_gateway import server


class _Clock:
    def __init__(self, now: float = 1_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


def _session(proc_id: str, *, internal: bool = False, key: str = "chat-key", **extra) -> ProcessSession:
    return ProcessSession(id=proc_id, command=f"cmd-{proc_id}", task_id="t", owner_task_id="t",
                          session_key=key, started_at=1_000_000.0, internal=internal, **extra)


def _ids(entries) -> list[str]:
    return [entry["session_id"] for entry in entries]


@pytest.fixture(autouse=True)
def _no_systemd_scope():
    original = module._SYSTEMD_SCOPE_AVAILABLE
    module._SYSTEMD_SCOPE_AVAILABLE = False
    yield
    module._SYSTEMD_SCOPE_AVAILABLE = original


def test_internal_entry_is_hidden_from_listing_but_resolvable():
    registry = ProcessRegistry(clock=_Clock())
    registry._running["proc_user"] = _session("proc_user")
    registry._running["proc_runner"] = _session("proc_runner", internal=True)

    assert _ids(registry.list_sessions()) == ["proc_user"]
    assert _ids(registry.list_sessions(session_key="chat-key")) == ["proc_user"]
    assert sorted(_ids(registry.list_sessions(include_internal=True))) == ["proc_runner", "proc_user"]
    assert registry.get("proc_runner") is registry._running["proc_runner"]


def test_exited_entry_leaves_listing_after_the_retention_window():
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    session = _session("proc_done", exited=True, exit_code=0, exited_at=clock.now)
    registry._finished[session.id] = session

    assert _ids(registry.list_sessions()) == ["proc_done"]
    clock.now += FINISHED_LISTING_RETENTION_SECONDS - 1
    assert _ids(registry.list_sessions()) == ["proc_done"]
    clock.now += 2
    assert registry.list_sessions() == []
    assert registry.get("proc_done") is session


def test_running_entry_never_ages_out_of_the_listing():
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    registry._running["proc_long"] = _session("proc_long")
    clock.now += 10 * FINISHED_LISTING_RETENTION_SECONDS

    assert _ids(registry.list_sessions()) == ["proc_long"]


@pytest.mark.platforms("posix")
def test_runner_past_its_lifetime_is_killed_and_reports_a_failed_delivery():
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    policy = InternalProcessPolicy(
        max_lifetime_seconds=60,
        expiry_output=json.dumps({"error": "too slow", "reason": "delivery_timeout"}))
    session = registry.spawn_local(
        f"{sys.executable} -c 'import time; time.sleep(60)'", task_id="t", session_key="chat-key",
        internal_policy=policy)
    session.notify_on_complete = True
    session.started_at = clock.now
    try:
        clock.now += 59
        assert registry.reap_overdue() == []
        assert not session.exited

        clock.now += 2
        assert registry.reap_overdue() == [session.id]
        assert session._completion_event.wait(10)
        assert (session.completion_reason, session.termination_source) == ("killed", "lifetime_exceeded")
        event = registry.completion_queue.get_nowait()
        assert json.loads(event["output"])["reason"] == "delivery_timeout"
    finally:
        registry.kill_all()


def test_runner_within_its_lifetime_is_left_alone():
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    session = _session("proc_runner", internal=True, max_lifetime_seconds=60)
    registry._running[session.id] = session
    clock.now += 30

    assert registry.reap_overdue() == []


def test_reaping_runs_in_the_spawning_context(monkeypatch):
    owner = ContextVar("owner", default="timer-thread")
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    seen = []
    monkeypatch.setattr(registry, "kill_process", lambda sid, **kw: seen.append(owner.get()) or {"status": "killed"})
    session = _session("proc_runner", internal=True, max_lifetime_seconds=60)
    owner.set("profile-a")
    session._scope = copy_context()
    owner.set("someone-else")
    registry._running[session.id] = session
    clock.now += 61

    assert registry.reap_overdue() == [session.id]
    assert seen == ["profile-a"]


def test_delivery_runner_is_spawned_internal_with_a_failure_payload(monkeypatch):
    calls = []

    def fake_terminal_tool(command, **kwargs):
        calls.append(kwargs)
        return json.dumps({"output": "Background process started", "session_id": "proc_test1234"})

    import tools.terminal_tool as terminal_tool_module

    monkeypatch.setattr(terminal_tool_module, "terminal_tool", fake_terminal_tool)
    agent = SimpleNamespace(session_id="s1")

    bot_mode_dm._spawn_delivery("run-it", "researcher", task_id="t", agent=agent)

    policy = calls[0]["_internal"]
    assert policy.max_lifetime_seconds > 0
    payload = json.loads(policy.expiry_output)
    assert payload["reason"] == "delivery_timeout" and "researcher" in payload["error"]


def _rpc(method, **params):
    return server.handle_request({"id": "r", "method": method, "params": {"session_id": "ui-chat", **params}})


@pytest.fixture()
def tray_registry(monkeypatch):
    registry = ProcessRegistry()
    registry._running["proc_user"] = _session("proc_user")
    registry._running["proc_runner"] = _session("proc_runner", internal=True)
    monkeypatch.setattr(module, "process_registry", registry)
    server._sessions["ui-chat"] = {"session_key": "chat-key", "history": [], "agent": SimpleNamespace()}
    yield registry
    server._sessions.pop("ui-chat", None)


def test_tray_lists_only_user_processes(tray_registry):
    processes = _rpc("process.list")["result"]["processes"]
    assert _ids(processes) == ["proc_user"]


def test_tray_cannot_kill_an_internal_process(tray_registry):
    response = _rpc("process.kill", process_id="proc_runner")
    assert response["error"]["code"] == 4044
    assert not tray_registry._running["proc_runner"].exited


def test_stop_all_spares_internal_processes(tray_registry, monkeypatch):
    killed = []
    monkeypatch.setattr(tray_registry, "kill_process",
                        lambda sid, **kw: killed.append(sid) or {"status": "killed"})
    _rpc("process.stop")
    assert killed == ["proc_user"]
