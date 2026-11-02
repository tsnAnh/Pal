import json
import subprocess
import sys

import pytest

import tools.process_registry as module
from hermes_constants import get_hermes_home, reset_hermes_home_override, set_hermes_home_override
from tools.process_registry import InternalProcessPolicy, ProcessRegistry, ProcessSession

pytestmark = pytest.mark.platforms("posix")

LIFETIME = 3420
START = 1_000_000.0


class _Clock:
    now = START

    def __call__(self) -> float:
        return self.now


@pytest.fixture()
def orphan(monkeypatch):
    monkeypatch.setattr(module, "HEARTBEAT_TICK_SECONDS", 3600)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    yield child
    child.kill()
    child.wait()


def _checkpoint_runner(pid: int) -> None:
    registry = ProcessRegistry()
    session = ProcessSession(
        id="proc_runner", command="deliver", task_id="t", owner_task_id="t", session_key="chat-key",
        pid=pid, pid_scope="host", started_at=START, internal=True, max_lifetime_seconds=LIFETIME,
        lifetime_expiry_output=json.dumps({"reason": "delivery_timeout"}))
    registry._running[session.id] = session
    registry._write_checkpoint()


def _recover(clock) -> tuple[ProcessRegistry, ProcessSession]:
    registry = ProcessRegistry(clock=clock)
    assert registry.recover_from_checkpoint() == 1
    return registry, registry._running["proc_runner"]


def test_internal_marking_and_lifetime_survive_a_checkpoint(orphan):
    _checkpoint_runner(orphan.pid)

    registry, session = _recover(_Clock())

    assert session.internal and session.max_lifetime_seconds == LIFETIME
    assert json.loads(session.lifetime_expiry_output)["reason"] == "delivery_timeout"
    assert registry.list_sessions() == []


def test_recovered_runner_keeps_the_timer_thread_alive(orphan):
    _checkpoint_runner(orphan.pid)

    registry, _session = _recover(_Clock())

    assert registry._heartbeat_thread is not None and registry._heartbeat_thread.is_alive()


def test_recovered_runner_is_reaped_under_its_own_profile(orphan, tmp_path):
    profile_home = tmp_path / "profiles" / "owner"
    profile_home.mkdir(parents=True)
    default_checkpoint = get_hermes_home() / "processes.json"
    token = set_hermes_home_override(str(profile_home))
    try:
        _checkpoint_runner(orphan.pid)
        clock = _Clock()
        registry, session = _recover(clock)
    finally:
        reset_hermes_home_override(token)
    assert json.loads((profile_home / "processes.json").read_text())[0]["session_id"] == "proc_runner"

    clock.now += LIFETIME + 1
    assert registry.reap_overdue() == [session.id]

    assert json.loads((profile_home / "processes.json").read_text()) == []
    assert not default_checkpoint.exists()
    assert session.completion_reason == "killed"
