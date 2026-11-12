from __future__ import annotations

import json
import logging
import os
import stat
import subprocess
import time
import types

import pytest

from tui_gateway import kit_host, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

CANARY = "ghp_CANARYTOKEN0123456789abcdefghijklmnop"
NAMES = {"host.kit.status", "host.kit.update", "host.kit.add_project", "host.kit.reload",
         "host.kit.job"}

SCRIPT = """#!/bin/sh
D="$(dirname "$0")"
printf '%s\\n' "$*" >> "$D/argv.log"
env > "$D/env.log"
MODE="$(cat "$D/mode" 2>/dev/null)"
case "$MODE" in
  ok) echo '{"ok":true,"message":"fine","next":{"action":"run: rm -rf /tmp/kit-canary"},"data":{"version":"1.2.3","status":"ready"},"extra":{"ignored":true}}' ;;
  refused0) echo '{"ok":false,"code":"request_refused","message":"host runs only from the owners own shell","next":{"action":"open a terminal"}}' ;;
  refused1) echo '{"ok":false,"code":"request_refused","message":"host runs only from the owners own shell"}' ; echo "usage: faker-kit" >&2 ; exit 2 ;;
  otherfail) echo '{"ok":false,"code":"disk_full","message":"no space left","next":{"action":"free space"}}' ; exit 1 ;;
  codeonly) echo '{"ok":true,"code":"degraded","message":"half"}' ;;
  oldkit) echo "faker-kit: error: argument command: invalid choice: 'host'" >&2 ; exit 2 ;;
  garbage) echo "not json CANARY_TOKEN" ; echo "$CANARY_ENV" >&2 ;;
  array) echo '[1,2]' ;;
  unsupported) echo "usage: faker-kit [-h] {status}" >&2 ; exit 2 ;;
  fail) echo "boom $SECRET_ECHO" >&2 ; exit 1 ;;
  sleep) sleep 30 ;;
  slow) sleep 1 ; echo '{"version":"1","status":"ready"}' ;;
  big) head -c 400000 /dev/zero | tr '\\0' 'x' ;;
esac
"""


@pytest.fixture
def kit(tmp_path, monkeypatch):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    exe = bindir / "faker-kit"
    exe.write_text(SCRIPT)
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin:/bin")
    kit_host.reset()

    class Kit:
        dir = bindir

        def mode(self, value):
            (bindir / "mode").write_text(value)

        def argv(self):
            path = bindir / "argv.log"
            return path.read_text().splitlines() if path.exists() else []

        def env(self):
            return (bindir / "env.log").read_text()

    fake = Kit()
    fake.mode("ok")
    yield fake
    kit_host.reset()


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def _finish(response, timeout=10):
    assert "error" not in response, response
    job = response["result"]
    METHODS["host.kit.job"].result.model_validate(job)
    deadline = time.monotonic() + timeout
    while job["state"] == "running" and time.monotonic() < deadline:
        time.sleep(0.02)
        job = _call("host.kit.job", {"job_id": job["job_id"]})["result"]
    return job


JOB_CALLS = [("host.kit.update", {}, "host update"),
             ("host.kit.add_project", {"repo": "octo/hello-world.x"}, "add-project octo/hello-world.x"),
             ("host.kit.reload", {"target": "routes"}, "host reload routes"),
             ("host.kit.reload", {"target": "gateway"}, "host reload gateway")]


def test_status_runs_exact_argv_and_ignores_unknown_fields(kit):
    response = _call("host.kit.status")
    METHODS["host.kit.status"].result.model_validate(response["result"])
    assert response["result"] == {"version": "1.2.3", "status": "ready", "message": "fine",
                                  "next_action": "run: rm -rf /tmp/kit-canary"}
    assert kit.argv() == ["host status --json"]


@pytest.mark.parametrize("method,params,line", JOB_CALLS)
def test_each_allow_listed_subcommand_runs_with_exact_argv(kit, method, params, line):
    job = _finish(_call(method, params))
    assert job["state"] == "succeeded" and job["report"]["version"] == "1.2.3"
    assert kit.argv() == [f"{line} --json"]


def test_commands_are_argv_lists_without_a_shell(kit, monkeypatch):
    seen = []
    real = subprocess.Popen

    def spy(argv, **kwargs):
        seen.append((argv, kwargs))
        return real(argv, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", spy)
    _finish(_call("host.kit.add_project", {"repo": "octo/hello"}))
    argv, kwargs = seen[0]
    assert argv == ["faker-kit", "add-project", "octo/hello", "--json"]
    assert kwargs["shell"] is False and kwargs["stdin"] == subprocess.DEVNULL


def test_unknown_subcommands_are_refused_and_not_methods(kit):
    for name in ("shell", "status; id", "--version", "", "STATUS", "add_project"):
        with pytest.raises(ValueError):
            kit_host.build_argv(name)
    assert {"host.kit.exec", "host.kit.run"}.isdisjoint(METHODS)
    assert set(kit_host.SUBCOMMANDS) == {"status", "update", "add-project", "reload"}
    assert "error" in _call("host.kit.exec")
    assert kit.argv() == []


@pytest.mark.parametrize("repo", ["../etc/passwd", "a/../b", "owner/repo name", "--foo", "-x/y", "owner/repo\n--json",
                                  "owner/repo\nrm", "owner", "owner/", "/repo", "a/b/c", "o;id/r", "o/r$(id)", "",
                                  "o/..", "a" * 40 + "/r", "o/" + "r" * 101, 7, None])
def test_invalid_repo_is_refused_without_running_the_kit(kit, repo):
    response = _call("host.kit.add_project", {"repo": repo})
    assert response["error"]["code"] in (4101, -32602) or "error" in response
    assert kit.argv() == []


@pytest.mark.parametrize("target", ["Gateway", "all", "routes --foo", "", None, "gateway\n"])
def test_invalid_reload_target_is_refused(kit, target):
    assert "error" in _call("host.kit.reload", {"target": target})
    assert kit.argv() == []


def test_unparseable_output_is_typed_with_a_redacted_bounded_tail(kit):
    kit.mode("garbage")
    response = _call("host.kit.status")
    data = response["error"]["data"]
    assert data["code"] == "invalid_output" and data["subcommand"] == "status"
    assert len(data["tail"]) <= kit_host.TAIL_CHARS
    job = _finish(_call("host.kit.update"))
    assert job["state"] == "failed" and job["error"]["code"] == "invalid_output"


def test_tail_redacts_secret_shaped_values(kit, monkeypatch):
    monkeypatch.setattr(kit_host, "_execute", lambda name, argv, timeout: (1, "", f"login failed token {CANARY}"))
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "failed" and CANARY not in json.dumps(data)


def test_non_object_json_is_invalid_output(kit):
    kit.mode("array")
    assert _call("host.kit.status")["error"]["data"]["code"] == "invalid_output"


def test_missing_kit_is_kit_unavailable(kit, tmp_path, monkeypatch):
    empty = tmp_path / "empty"
    empty.mkdir()
    monkeypatch.setenv("PATH", str(empty))
    response = _call("host.kit.status")
    assert response["error"]["data"]["code"] == "kit_unavailable"
    assert _finish(_call("host.kit.update"))["error"]["code"] == "kit_unavailable"


def test_unsupported_subcommand_names_it(kit):
    kit.mode("unsupported")
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "kit_unsupported" and data["subcommand"] == "status"
    job = _finish(_call("host.kit.reload", {"target": "routes"}))
    assert job["error"]["code"] == "kit_unsupported" and job["error"]["subcommand"] == "reload"


def test_a_failing_kit_is_failed_with_a_tail(kit):
    kit.mode("fail")
    job = _finish(_call("host.kit.update"))
    assert job["state"] == "failed" and job["error"]["code"] == "failed" and "boom" in job["error"]["tail"]


def test_timeout_is_typed_and_the_child_is_killed(kit, monkeypatch):
    kit.mode("sleep")
    monkeypatch.setattr(kit_host, "STATUS_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(kit_host, "JOB_TIMEOUT_SECONDS", 0.3)
    started = time.monotonic()
    assert _call("host.kit.status")["error"]["data"]["code"] == "timeout"
    assert _finish(_call("host.kit.update"))["error"]["code"] == "timeout"
    assert time.monotonic() - started < 10


def test_one_operation_at_a_time_and_identical_start_is_idempotent(kit):
    kit.mode("slow")
    first = _call("host.kit.update")["result"]
    again = _call("host.kit.update")["result"]
    assert again["job_id"] == first["job_id"] and again["state"] == "running"
    busy = _call("host.kit.reload", {"target": "gateway"})
    assert busy["error"]["code"] == 4409 and busy["error"]["data"]["code"] == "busy"
    assert _call("host.kit.add_project", {"repo": "o/r"})["error"]["code"] == 4409
    assert _call("host.kit.reload", {"target": "routes"})["error"]["code"] == 4409
    assert _finish({"result": first})["state"] == "succeeded"
    assert kit.argv() == ["host update --json"]
    assert _finish(_call("host.kit.update"))["state"] == "succeeded"


def test_unknown_job_is_typed(kit):
    assert _call("host.kit.job", {"job_id": "nope"})["error"]["code"] == 4404


def test_output_is_bounded(kit, monkeypatch):
    kit.mode("big")
    monkeypatch.setattr(kit_host, "MAX_OUTPUT_BYTES", 2048)
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "invalid_output" and len(data["tail"]) <= kit_host.TAIL_CHARS


def test_child_env_has_no_token_variables(kit, monkeypatch):
    for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
        monkeypatch.setenv(name, CANARY)
    assert "result" in _call("host.kit.status")
    env = kit.env()
    assert CANARY not in env and "GITHUB_TOKEN" not in env and "GH_TOKEN" not in env


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_worker_and_capability_less_connections_cannot_reach_the_kit_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_secondary_profile_ticket_is_refused_for_every_method(kit):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        extra = {"host.kit.add_project": {"repo": "o/r"}, "host.kit.reload": {"target": "routes"},
                 "host.kit.job": {"job_id": "x"}}
        for name in NAMES:
            assert _call(name, extra.get(name))["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert kit.argv() == []


def test_no_secret_in_responses_or_logs(kit, caplog, monkeypatch):
    monkeypatch.setenv("GITHUB_TOKEN", CANARY)
    kit.mode("fail")
    caplog.set_level(logging.DEBUG)
    out = [_call("host.kit.status"), _finish(_call("host.kit.update"))]
    kit.mode("garbage")
    out.append(_call("host.kit.status"))
    assert CANARY not in json.dumps(out) and CANARY not in caplog.text
    assert CANARY not in " ".join(kit.argv())


def test_kit_and_github_owner_gates_do_not_shadow_each_other(kit):
    assert "result" in _call("host.kit.status")
    assert "result" in _call("github.oauth.config.get")
    assert "result" in _call("host.kit.status")


@pytest.mark.parametrize("mode", ["refused0", "refused1"])
def test_request_refused_is_its_own_state_with_exit_zero_or_nonzero(kit, mode):
    kit.mode(mode)
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "request_refused" and data["kit_code"] == "request_refused"
    assert "owners own shell" in data["message"] and data["tail"] is None
    job = _finish(_call("host.kit.update"))
    assert job["state"] == "failed" and job["error"]["code"] == "request_refused"
    assert job["error"]["code"] != "kit_unsupported"
    METHODS["host.kit.job"].result.model_validate(job)


def test_a_refusal_is_not_retried_or_worked_around(kit, monkeypatch):
    kit.mode("refused1")
    seen = []
    real = subprocess.Popen

    def spy(argv, **kwargs):
        seen.append((argv, kwargs))
        return real(argv, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", spy)
    _call("host.kit.status")
    assert len(seen) == 1 and kit.argv() == ["host status --json"]
    kwargs = seen[0][1]
    assert kwargs["stdin"] == subprocess.DEVNULL and kwargs["stdout"] == subprocess.PIPE
    assert "tty" not in kwargs and "preexec_fn" not in kwargs and "pass_fds" not in kwargs


def test_ok_false_with_another_code_surfaces_the_kit_code_and_next_action_as_text(kit):
    kit.mode("otherfail")
    data = _call("host.kit.status")["error"]["data"]
    assert (data["code"], data["kit_code"], data["message"], data["next_action"]) == (
        "failed", "disk_full", "no space left", "free space")
    job = _finish(_call("host.kit.update"))
    assert job["error"]["kit_code"] == "disk_full" and job["error"]["next_action"] == "free space"


def test_a_code_on_an_ok_body_is_surfaced(kit):
    kit.mode("codeonly")
    data = _call("host.kit.status")["error"]["data"]
    assert data["kit_code"] == "degraded" and data["message"] == "half"


def test_next_action_is_shown_never_run(kit, tmp_path):
    marker = tmp_path / "ran"
    (kit.dir / "mode").write_text("ok")
    script = kit.dir / "faker-kit"
    script.write_text(script.read_text().replace("rm -rf /tmp/kit-canary", f"touch {marker}"))
    result = _call("host.kit.status")["result"]
    assert result["next_action"] == f"run: touch {marker}" and not marker.exists()
    assert kit.argv() == ["host status --json"]


def test_an_old_kit_without_the_host_subcommand_is_unsupported(kit):
    kit.mode("oldkit")
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "kit_unsupported" and data["subcommand"] == "status"


def test_secret_in_a_kit_body_is_redacted(kit, monkeypatch):
    monkeypatch.setattr(kit_host, "_execute", lambda name, argv, timeout: (
        1, json.dumps({"ok": False, "code": "x", "message": f"bad {CANARY}", "next": {"action": CANARY}}), ""))
    data = _call("host.kit.status")["error"]["data"]
    assert CANARY not in json.dumps(data)
