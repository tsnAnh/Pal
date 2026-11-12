from __future__ import annotations

import io
import json
import os
import subprocess
import types
from pathlib import Path

import pytest
from hermes_cli.update_lock import process_create_time

from tui_gateway import host_update, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

NAMES = {"host.update.check", "host.update.apply", "host.update.status"}
CANARY = "ghp_CANARYTOKEN0123456789abcdefghijklmnop"
COMMIT = "a" * 40


def _call(method, params=None):
    response = server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
    if "result" in response:
        METHODS[method].result.model_validate(response["result"])
    return response


class FakeProc:
    def __init__(self, lines, code):
        self.stdout = io.StringIO("".join(f"{line}\n" for line in lines))
        self.code = code

    def wait(self):
        return self.code


@pytest.fixture
def host(monkeypatch, tmp_path):
    root = tmp_path / "install"
    (root / ".git").mkdir(parents=True)
    fake = types.SimpleNamespace(runs=0, dirty=False, spawned=[], run_calls=[], update_running=False,
                                 check=(0, "✓ Already up to date.\n", ""), recovery=False, proc=None)
    monkeypatch.setattr(host_update, "install_root", lambda: root)
    monkeypatch.setattr(host_update, "active_runs", lambda: fake.runs)
    monkeypatch.setattr(host_update, "current_version",
                        lambda: {"version": "0.9.0+3", "commit": COMMIT, "dirty": fake.dirty})
    monkeypatch.setattr(host_update, "update_env", lambda: {"PATH": "/usr/bin"})
    monkeypatch.setattr(host_update, "release_notes_url", lambda root: "https://github.com/acme/pal/releases")
    monkeypatch.setattr(host_update, "recovery_needed", lambda root: fake.recovery)
    monkeypatch.setattr("hermes_cli.update_lock.update_in_progress", lambda root=None: fake.update_running)

    def run(argv, **kwargs):
        fake.run_calls.append(list(argv))
        code, out, err = fake.check
        return subprocess.CompletedProcess(argv, code, out, err)

    def popen(argv, **kwargs):
        if list(argv) == host_update.UPDATE_ARGV:
            fake.run_calls.append(list(argv))
            return fake.proc
        fake.spawned.append({"argv": list(argv), "kwargs": kwargs})
        return types.SimpleNamespace(pid=1)

    monkeypatch.setattr(host_update.subprocess, "run", run)
    monkeypatch.setattr(host_update.subprocess, "Popen", popen)
    monkeypatch.setattr(host_update, "_detach_kwargs", dict)
    return fake


def test_check_reports_up_to_date(host):
    result = _call("host.update.check")["result"]
    assert result["status"] == "up_to_date" and result["commits_behind"] == 0
    assert result["version"] == "0.9.0+3" and result["commit"] == COMMIT and result["blockers"] == []
    assert host.run_calls == [host_update.CHECK_ARGV]


def test_check_reports_commits_behind_and_release_link(host):
    host.check = (0, "→ Update channel: main\n⚕ Update available: 7 commits behind origin/main.\n", "")
    result = _call("host.update.check")["result"]
    assert result["status"] == "update_available" and result["commits_behind"] == 7
    assert result["release_notes_url"] == "https://github.com/acme/pal/releases"


def test_check_reports_a_pinned_release_without_a_count(host):
    host.check = (0, "→ Selected release available: v2.1.0\n", "")
    result = _call("host.update.check")["result"]
    assert result["status"] == "update_available" and result["commits_behind"] is None


def test_check_offline_is_typed_and_blocks(host):
    host.check = (1, "", "fatal: unable to access 'https://x/': Could not resolve host: x")
    result = _call("host.update.check")["result"]
    assert result["status"] == "unknown" and result["error"] == "no_network" and "no_network" in result["blockers"]


def test_check_timeout_is_offline(host, monkeypatch):
    def slow(argv, **kwargs):
        raise subprocess.TimeoutExpired(argv, 1)
    monkeypatch.setattr(host_update.subprocess, "run", slow)
    assert _call("host.update.check")["result"]["error"] == "no_network"


def test_check_lists_every_blocker(host):
    host.runs, host.dirty, host.update_running = 2, True, True
    host.check = (1, "Could not resolve host", "")
    blockers = _call("host.update.check")["result"]["blockers"]
    assert set(blockers) == {"turn_running", "dirty_install", "update_running", "no_network"}


def test_apply_is_refused_while_a_turn_runs_without_confirm(host):
    host.runs = 1
    result = _call("host.update.apply")["result"]
    assert result["outcome"] == "refused" and result["blockers"] == ["turn_running"]
    assert host.spawned == [] and host_update.read_state() == {}


def test_apply_with_confirm_proceeds_while_a_turn_runs(host):
    host.runs = 1
    result = _call("host.update.apply", {"confirm_turns": True})["result"]
    assert result["outcome"] == "started" and result["update"]["state"] == "running"
    assert len(host.spawned) == 1


def test_confirm_does_not_override_other_blockers(host):
    host.dirty = True
    result = _call("host.update.apply", {"confirm_turns": True})["result"]
    assert result["outcome"] == "refused" and "dirty_install" in result["blockers"] and host.spawned == []


def test_second_apply_returns_the_running_update(host, monkeypatch):
    first = _call("host.update.apply")["result"]
    state = host_update.read_state()
    host_update.write_state({**state, "pid": os.getpid(),
                                   "pid_create_time": process_create_time()})
    second = _call("host.update.apply")["result"]
    assert second["outcome"] == "already_running" and second["update"]["run_id"] == first["update"]["run_id"]
    assert len(host.spawned) == 1


def test_a_runner_that_died_is_reported_as_interrupted(host):
    host_update.write_state({"run_id": "r1", "state": "running", "phase": "downloading", "pid": 2 ** 22 + 1,
                             "started_at": 1.0, "tail": ["→ Fetching from origin..."]})
    result = _call("host.update.status")["result"]
    assert result["state"] == "failed" and result["failure"] == "interrupted" and result["phase"] == "downloading"


def test_the_spawned_command_is_fixed_and_carries_no_client_text(host):
    injected = "; touch /tmp/pwned"
    assert _call("host.update.apply", {"confirm_turns": True, "channel": injected})["error"]["code"] == 4000
    assert host.spawned == []
    _call("host.update.apply")
    argv = host.spawned[0]["argv"]
    assert argv[:-1] == host_update.RUNNER_ARGV and argv[-1] == host_update.read_state()["run_id"]
    assert "shell" not in host.spawned[0]["kwargs"]
    assert not any(injected in part for part in argv)


def test_update_and_check_argv_are_fixed_lists():
    assert host_update.UPDATE_ARGV[1:] == ["-m", "hermes_cli.main", "update", "--yes"]
    assert host_update.CHECK_ARGV[1:] == ["-m", "hermes_cli.main", "update", "--check"]
    assert "shell=True" not in Path(host_update.__file__).read_text()


def _run(host, lines, code):
    host_update.write_state({"run_id": "r1", "state": "running", "phase": "preparing", "started_at": 1.0,
                             "from_commit": COMMIT, "tail": []})
    host.proc = FakeProc(lines, code)
    return host_update.run_update("r1"), _call("host.update.status")["result"]


def test_a_successful_run_walks_the_phases(host):
    code, state = _run(host, ["→ Fetching updates...", "→ Found 3 new commit(s)", "→ Pulling updates...",
                              "→ Running post-update steps...", "→ Restarting gateway"], 0)
    assert code == 0 and state["state"] == "succeeded" and state["phase"] == "finished"
    assert state["failure"] is None and state["tail"][-1] == "→ Restarting gateway"


def test_failure_before_the_switch_leaves_the_old_install_untouched(host):
    code, state = _run(host, ["→ Fetching updates...", "fatal: unable to access 'https://x': Could not resolve host: x"], 1)
    assert code == 1 and state["state"] == "failed" and state["phase"] == "downloading"
    assert state["failure"] == "no_network" and state["left_behind"] == "nothing"
    assert state["version"] == "0.9.0+3" and state["from_commit"] == COMMIT


def test_failure_after_the_switch_keeps_the_old_version_running(host):
    _, state = _run(host, ["→ Pulling updates...", "✗ Merge conflict"], 1)
    assert state["state"] == "failed" and state["phase"] == "applying"
    assert state["failure"] == "update_failed" and state["left_behind"] == "old_version_running"


def test_a_half_updated_tree_is_a_typed_recovery_state(host):
    host.recovery = True
    _, state = _run(host, ["→ Pulling updates...", "killed"], 1)
    assert state["state"] == "needs_recovery" and state["left_behind"] == "tree_needs_recovery"


def test_progress_output_is_redacted_and_bounded(host):
    lines = [f"line {i}" for i in range(100)] + [f"Authorization: Bearer {CANARY}", f"token={CANARY}", "x" * 1000]
    _, state = _run(host, lines, 0)
    raw = host_update.state_path().read_text()
    assert CANARY not in raw and CANARY not in json.dumps(state)
    assert len(state["tail"]) == host_update.TAIL_LINES
    assert all(len(line) <= host_update.TAIL_LINE_CHARS for line in state["tail"])


def test_the_update_environment_drops_github_tokens(monkeypatch):
    monkeypatch.setenv("GH_TOKEN", CANARY)
    monkeypatch.setenv("GITHUB_TOKEN", CANARY)
    env = host_update.update_env()
    assert CANARY not in json.dumps(env) and "GH_TOKEN" not in env and "GITHUB_TOKEN" not in env


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_worker_and_capability_less_connections_cannot_reach_the_update_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_secondary_profile_ticket_is_refused(host):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        for name in NAMES:
            assert _call(name)["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert host.spawned == [] and host.run_calls == [] and host_update.read_state() == {}
