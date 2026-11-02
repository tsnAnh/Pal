"""Internal background processes (bot delivery runners) are hidden from user-facing surfaces,
stay resolvable for their owner, and stale or overdue entries clean themselves up."""

import json
import os
import sys
import threading
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


@pytest.fixture()
def quiet_timer_thread(monkeypatch):
    monkeypatch.setattr(module, "HEARTBEAT_TICK_SECONDS", 3600)


@pytest.mark.platforms("posix")
def test_runner_past_its_lifetime_is_killed_and_reports_a_failed_delivery(quiet_timer_thread):
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


EXPIRY_PAYLOAD = json.dumps({"error": "too slow", "reason": "delivery_timeout"})


def _spawn_runner(registry, command, lifetime=60):
    session = registry.spawn_local(
        command, task_id="t", session_key="chat-key",
        internal_policy=InternalProcessPolicy(max_lifetime_seconds=lifetime, expiry_output=EXPIRY_PAYLOAD))
    session.notify_on_complete = True
    return session


def _sleeper() -> str:
    return f"{sys.executable} -c 'import time; time.sleep(60)'"


@pytest.mark.platforms("posix")
def test_failed_lifetime_kill_adds_no_text_and_is_retried(quiet_timer_thread, monkeypatch):
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    session = _spawn_runner(registry, _sleeper())
    real_signal_kill = registry._signal_kill
    attempts = []

    def flaky_signal_kill(*args):
        attempts.append(1)
        if len(attempts) == 1:
            return {"status": "error", "error": "transport down", "session_id": session.id}
        return real_signal_kill(*args)

    monkeypatch.setattr(registry, "_signal_kill", flaky_signal_kill)
    try:
        clock.now += 61
        assert registry.reap_overdue() == []
        assert not session.exited
        assert "delivery_timeout" not in session.output_buffer

        assert registry.reap_overdue() == [session.id]
        assert session._completion_event.wait(10)
        assert session.output_buffer.count("delivery_timeout") == 1
        assert json.loads(registry.completion_queue.get_nowait()["output"])["reason"] == "delivery_timeout"
    finally:
        registry.kill_all()


@pytest.mark.platforms("posix")
def test_concurrent_lifetime_sweeps_attach_the_failure_once(quiet_timer_thread, monkeypatch):
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    session = _spawn_runner(registry, _sleeper())
    real_terminate = registry._terminate_host_pid
    first_kill_started, release_first_kill, terminations = threading.Event(), threading.Event(), []

    def gated_terminate(*args, **kwargs):
        terminations.append(1)
        if len(terminations) == 1:
            first_kill_started.set()
            assert release_first_kill.wait(10)
        return real_terminate(*args, **kwargs)

    monkeypatch.setattr(registry, "_terminate_host_pid", gated_terminate)
    first_sweep = []
    first = threading.Thread(target=lambda: first_sweep.extend(registry.reap_overdue()))
    try:
        clock.now += 61
        first.start()
        assert first_kill_started.wait(10)
        registry.reap_overdue()
        release_first_kill.set()
        first.join(10)

        assert first_sweep == [session.id]
        assert session._completion_event.wait(10)
        assert session.output_buffer.count("delivery_timeout") == 1
        assert json.loads(registry.completion_queue.get_nowait()["output"])["reason"] == "delivery_timeout"
    finally:
        release_first_kill.set()
        registry.kill_all()


@pytest.mark.platforms("posix")
def test_runner_that_exits_on_its_own_before_the_reap_gets_no_failure_text(quiet_timer_thread, monkeypatch, tmp_path):
    fifo = tmp_path / "release"
    os.mkfifo(fifo)
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    session = _spawn_runner(registry, f"sh -c 'read line < {fifo}'")
    real_kill = registry.kill_process

    def kill_after_it_finished(session_id, **kwargs):
        with open(fifo, "w") as release:
            release.write("go\n")
        assert session._completion_event.wait(10)
        return real_kill(session_id, **kwargs)

    monkeypatch.setattr(registry, "kill_process", kill_after_it_finished)
    try:
        clock.now += 61
        registry.reap_overdue()

        assert (session.exit_code, session.completion_reason) == (0, "exited")
        assert "delivery_timeout" not in session.output_buffer
        assert "delivery_timeout" not in registry.completion_queue.get_nowait()["output"]
    finally:
        registry.kill_all()


def test_listing_never_reaps_an_overdue_runner(monkeypatch):
    clock = _Clock()
    registry = ProcessRegistry(clock=clock)
    registry._running["proc_runner"] = _session("proc_runner", internal=True, max_lifetime_seconds=60)
    clock.now += 61

    def refuse_kill(*args, **kwargs):
        pytest.fail("a listing must not kill anything")

    monkeypatch.setattr(registry, "kill_process", refuse_kill)

    assert _ids(registry.list_sessions(include_internal=True)) == ["proc_runner"]
    assert registry.list_sessions() == []


def test_running_count_excludes_internal_runners():
    registry = ProcessRegistry(clock=_Clock())
    registry._running["proc_user"] = _session("proc_user")
    registry._running["proc_runner"] = _session("proc_runner", internal=True)

    assert registry.count_running() == 1
    assert len(registry.list_sessions()) == registry.count_running()


def test_registry_built_without_init_lists_sessions():
    registry = ProcessRegistry.__new__(ProcessRegistry)
    registry._running = {"proc_user": _session("proc_user")}
    registry._finished = {}
    registry._lock = threading.Lock()

    assert _ids(registry.list_sessions()) == ["proc_user"]


def test_agent_tool_listing_includes_pending_runners(monkeypatch):
    registry = ProcessRegistry(clock=_Clock())
    registry._running["proc_user"] = _session("proc_user")
    registry._running["proc_runner"] = _session("proc_runner", internal=True)
    monkeypatch.setattr(module, "process_registry", registry)

    assert sorted(_ids(module._list_processes("t")["processes"])) == ["proc_runner", "proc_user"]


@pytest.mark.platforms("posix")
def test_agent_close_and_gateway_shutdown_still_kill_runners(monkeypatch):
    import run_agent
    import tools.computer_use.tool as computer_use
    from agent.client_lifecycle import ClientLifecycleMixin
    from gateway.run_shutdown import GatewayShutdownMixin

    monkeypatch.setattr(run_agent, "cleanup_vm", lambda *a, **k: None)
    monkeypatch.setattr(run_agent, "cleanup_browser", lambda *a, **k: None)
    monkeypatch.setattr(computer_use, "release_computer_use_session", lambda *a, **k: None)
    registry = ProcessRegistry()
    monkeypatch.setattr(module, "process_registry", registry)
    policy = InternalProcessPolicy(max_lifetime_seconds=3420)
    closed = registry.spawn_local(_sleeper(), task_id="turn-1", owner_task_id="turn-1", internal_policy=policy)
    shut_down = registry.spawn_local(_sleeper(), task_id="turn-2", owner_task_id="turn-2", internal_policy=policy)
    try:
        ClientLifecycleMixin._close_task_resources(SimpleNamespace(_process_owner_task_ids=("turn-1",)), "turn-1")
        assert closed.exited and not shut_down.exited

        GatewayShutdownMixin._stop_kill_tool_subprocesses("final")
        assert shut_down.exited
    finally:
        registry.kill_all()
