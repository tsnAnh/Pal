from __future__ import annotations

import json
import logging
import os
import stat
import subprocess
import time
import types
from pathlib import Path

import pytest

from tui_gateway import kit_host, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

pytestmark = pytest.mark.live_system_guard_bypass

CANARY = "ghp_CANARYTOKEN0123456789abcdefghijklmnop"
SECRET = "s3cr3t-owner-credential-CANARY-0123456789abcdef"
NAMES = {"host.kit.status", "host.kit.update", "host.kit.reload", "host.kit.rotate", "host.kit.job"}

SCRIPT = """#!/bin/sh
D="$(dirname "$0")"
printf '%s\\n' "$*" >> "$D/argv.log"
env > "$D/env.log"
if [ -t 0 ]; then echo notty > "$D/stdin.log"; else cat > "$D/stdin.log"; fi
MODE="$(cat "$D/mode" 2>/dev/null)"
case "$MODE" in
  rotated) echo '{"ok":true,"code":"ok","message":"rotated","next":null,"data":{"rotated":true,"created_at":"2026-01-02T03:04:05Z"}}' ;;
  created) echo '{"ok":true,"code":"ok","message":"updated","next":null,"data":{"owner_credential":{"created":true,"present":true,"created_at":"2026-01-02T03:04:05Z"}}}' ;;
  present) echo '{"ok":true,"code":"ok","message":"fine","next":null,"data":{"kit":{"installed_commit":"2eb2d975abcdef0123456789"},"owner_credential":{"present":true,"created":false,"created_at":"2026-01-02T03:04:05Z"}}}' ;;
  inprogress) echo '{"ok":false,"code":"update_in_progress","message":"another update is running","next":null,"data":{}}' ; exit 1 ;;
  leak) echo "echo $(cat "$D/stdin.log")" >&2 ; echo "bad" ;;
  ok) echo '{"ok":true,"message":"fine","next":{"action":"run: rm -rf /tmp/kit-canary"},"data":{"version":"1.2.3","status":"ready"},"extra":{"ignored":true}}' ;;
  failzero) echo '{"ok":false,"code":"github_unreachable","message":"offline","next":{"action":"sign_in_github"}}' ;;
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
    home = tmp_path / "kit-home"
    bindir = home / "bin"
    bindir.mkdir(parents=True)
    home.chmod(0o700)
    exe = bindir / "faker-kit"
    exe.write_text(SCRIPT)
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("FAKER_KIT_HOME", str(home))
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    kit_host.reset()

    class Kit:
        dir = bindir

        def secret(self, value=SECRET, mode=0o600):
            path = home / "host-secret"
            path.unlink(missing_ok=True)
            if value is not None:
                path.write_text(value + "\n")
                path.chmod(mode)

        def mode(self, value):
            (bindir / "mode").write_text(value)

        def argv(self):
            path = bindir / "argv.log"
            return path.read_text().splitlines() if path.exists() else []

        def env(self):
            return (bindir / "env.log").read_text()

        def stdin(self):
            return (bindir / "stdin.log").read_text()

    fake = Kit()
    fake.secret()
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


SECRET_FLAGS = "--json --secret-stdin"
JOB_CALLS = [("host.kit.update", {}, "host update"),
             ("host.kit.reload", {"target": "routes"}, "host reload routes"),
             ("host.kit.reload", {"target": "gateway"}, "host reload gateway"),
             ("host.kit.rotate", {}, "host rotate")]


def test_status_runs_exact_argv_and_sends_the_secret_on_stdin_only(kit):
    response = _call("host.kit.status")
    METHODS["host.kit.status"].result.model_validate(response["result"])
    assert response["result"] == {"version": "1.2.3", "status": "ready", "message": "fine",
                                  "next_action": "run: rm -rf /tmp/kit-canary", "credential": None}
    assert kit.argv() == [f"host status {SECRET_FLAGS}"]
    assert kit.stdin() == SECRET + "\n"
    assert SECRET not in kit.env() and SECRET not in " ".join(kit.argv())


@pytest.mark.parametrize("method,params,line", JOB_CALLS)
def test_each_allow_listed_subcommand_runs_with_exact_argv(kit, method, params, line):
    job = _finish(_call(method, params))
    assert job["state"] == "succeeded" and job["report"]["version"] == "1.2.3"
    assert kit.argv() == [f"{line} {SECRET_FLAGS}"]
    assert kit.stdin() == SECRET + "\n"


def test_argv_is_the_launcher_path_without_a_shell_and_stdin_is_a_pipe(kit, monkeypatch):
    seen = []
    real = subprocess.Popen

    def spy(argv, **kwargs):
        seen.append((argv, kwargs))
        return real(argv, **kwargs)

    monkeypatch.setattr(subprocess, "Popen", spy)
    _finish(_call("host.kit.rotate"))
    argv, kwargs = seen[0]
    assert argv == [str(kit.dir / "faker-kit"), "host", "rotate", "--json", "--secret-stdin"]
    assert kwargs["shell"] is False and kwargs["stdin"] == subprocess.PIPE
    assert SECRET not in json.dumps(argv) and SECRET not in json.dumps(kwargs, default=str)


def test_the_secret_file_is_reread_on_every_call(kit):
    _call("host.kit.status")
    kit.secret("second-value-0000")
    _call("host.kit.status")
    assert kit.stdin() == "second-value-0000\n"
    kit.secret("third-value-1111")
    assert _finish(_call("host.kit.rotate"))["state"] == "succeeded"
    assert kit.stdin() == "third-value-1111\n"


def test_first_update_without_a_secret_file_runs_without_stdin_and_reports_created(kit, monkeypatch):
    kit.secret(None)
    kit.mode("created")
    seen = []
    real = subprocess.Popen
    monkeypatch.setattr(subprocess, "Popen", lambda argv, **kw: (seen.append((argv, kw)), real(argv, **kw))[1])
    job = _finish(_call("host.kit.update"))
    assert job["state"] == "succeeded"
    assert job["report"]["credential"] == {"present": True, "created": True, "rotated": None,
                                           "created_at": "2026-01-02T03:04:05Z"}
    assert kit.argv() == ["host update --json"] and seen[0][1]["stdin"] == subprocess.DEVNULL
    assert kit.stdin() == ""


@pytest.mark.parametrize("method,params", [("host.kit.status", {}), ("host.kit.reload", {"target": "routes"}),
                                           ("host.kit.rotate", {})])
def test_other_subcommands_without_a_secret_file_are_credential_missing(kit, method, params):
    kit.secret(None)
    response = _call(method, params)
    if "error" not in response:
        response = {"error": {"data": _finish(response)["error"]}}
    data = response["error"]["data"]
    assert data["code"] == "credential_missing" and "first" in data["message"] and "Update kit" in data["message"]
    assert kit.argv() == []


@pytest.mark.parametrize("mode,content", [(0o644, SECRET), (0o660, SECRET), (0o600, ""), (0o600, "a" * 200)])
def test_unreadable_or_malformed_secret_file_is_credential_unreadable(kit, mode, content):
    kit.secret(content, mode)
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "credential_unreadable" and "host-secret" in data["message"]
    assert SECRET not in json.dumps(data) and kit.argv() == []
    assert _finish(_call("host.kit.update"))["error"]["code"] == "credential_unreadable"


def test_a_symlinked_secret_file_is_unreadable(kit, tmp_path):
    kit.secret(None)
    real = tmp_path / "real"
    real.write_text(SECRET)
    real.chmod(0o600)
    (Path(os.environ["FAKER_KIT_HOME"]) / "host-secret").symlink_to(real)
    assert _call("host.kit.status")["error"]["data"]["code"] == "credential_unreadable"
    assert kit.argv() == []


def test_unknown_subcommands_and_old_names_are_refused_and_not_methods(kit):
    for name in ("shell", "status; id", "--version", "", "STATUS", "refresh", "add-project", "add_project"):
        with pytest.raises(ValueError):
            kit_host.check_args(name)
    assert {"host.kit.exec", "host.kit.run", "host.kit.add_project"}.isdisjoint(METHODS)
    assert set(kit_host.SUBCOMMANDS) == {"status", "update", "reload", "rotate"}
    assert "error" in _call("host.kit.exec")
    assert _call("host.kit.add_project", {"repo": "o/r"})["error"]["code"] == -32601
    assert kit.argv() == []


@pytest.mark.parametrize("target", ["Gateway", "all", "routes --foo", "", None, "gateway\n"])
def test_invalid_reload_target_is_refused(kit, target):
    assert "error" in _call("host.kit.reload", {"target": target})
    assert kit.argv() == []


def test_rotate_takes_no_argument_and_returns_state_never_the_value(kit):
    kit.mode("rotated")
    job = _finish(_call("host.kit.rotate"))
    assert job["operation"] == "rotate" and job["state"] == "succeeded"
    assert job["report"]["credential"] == {"present": None, "created": None, "rotated": True,
                                           "created_at": "2026-01-02T03:04:05Z"}
    assert SECRET not in json.dumps(job)
    with pytest.raises(ValueError):
        kit_host.check_args("rotate", "now")


def test_status_surfaces_credential_state_and_commit_as_version(kit):
    kit.mode("present")
    result = _call("host.kit.status")["result"]
    assert result["version"] == "2eb2d975abcd"
    assert result["credential"] == {"present": True, "created": False, "rotated": None,
                                    "created_at": "2026-01-02T03:04:05Z"}


def test_unparseable_output_is_typed_with_a_redacted_bounded_tail(kit):
    kit.mode("garbage")
    response = _call("host.kit.status")
    data = response["error"]["data"]
    assert data["code"] == "invalid_output" and data["subcommand"] == "status"
    assert len(data["tail"]) <= kit_host.TAIL_CHARS
    job = _finish(_call("host.kit.update"))
    assert job["state"] == "failed" and job["error"]["code"] == "invalid_output"


def test_the_secret_echoed_by_a_misbehaving_kit_is_redacted_from_every_tail(kit, caplog):
    kit.mode("leak")
    caplog.set_level(logging.DEBUG)
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "invalid_output" and "[redacted]" in data["tail"]
    assert SECRET not in json.dumps(data) and SECRET not in caplog.text


def test_tail_redacts_secret_shaped_values(kit, monkeypatch):
    monkeypatch.setattr(kit_host, "_execute", lambda name, argv, timeout, secret=None: (1, "", f"login failed token {CANARY}"))
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "failed" and CANARY not in json.dumps(data)


def test_non_object_json_is_invalid_output(kit):
    kit.mode("array")
    assert _call("host.kit.status")["error"]["data"]["code"] == "invalid_output"


def test_missing_launcher_is_kit_unavailable(kit):
    (kit.dir / "faker-kit").unlink()
    response = _call("host.kit.status")
    assert response["error"]["data"]["code"] == "kit_unavailable"
    assert _finish(_call("host.kit.update"))["error"]["code"] == "kit_unavailable"


def test_a_launcher_on_path_is_not_used(kit, tmp_path, monkeypatch):
    (kit.dir / "faker-kit").unlink()
    other = tmp_path / "other"
    other.mkdir()
    shim = other / "faker-kit"
    shim.write_text(SCRIPT)
    shim.chmod(0o755)
    monkeypatch.setenv("PATH", f"{other}:/usr/bin:/bin")
    assert _call("host.kit.status")["error"]["data"]["code"] == "kit_unavailable"
    assert not (other / "argv.log").exists()


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
    assert _call("host.kit.rotate")["error"]["code"] == 4409
    assert _call("host.kit.reload", {"target": "routes"})["error"]["code"] == 4409
    assert _finish({"result": first})["state"] == "succeeded"
    assert kit.argv() == [f"host update {SECRET_FLAGS}"]
    assert _finish(_call("host.kit.update"))["state"] == "succeeded"


def test_update_in_progress_from_the_kit_is_busy_not_an_error_state(kit):
    kit.mode("inprogress")
    response = _call("host.kit.status")
    assert response["error"]["code"] == 4409
    assert response["error"]["data"]["code"] == "busy" and response["error"]["data"]["kit_code"] == "update_in_progress"
    job = _finish(_call("host.kit.rotate"))
    assert job["state"] == "failed" and job["error"]["code"] == "busy" and job["error"]["tail"] is None
    METHODS["host.kit.job"].result.model_validate(job)


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
        extra = {"host.kit.reload": {"target": "routes"}, "host.kit.job": {"job_id": "x"}}
        for name in NAMES:
            assert _call(name, extra.get(name))["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert kit.argv() == []


def test_no_secret_in_responses_logs_or_exceptions(kit, caplog, monkeypatch):
    monkeypatch.setenv("GITHUB_TOKEN", CANARY)
    caplog.set_level(logging.DEBUG)
    out = []
    for mode in ("fail", "garbage", "leak", "rotated", "present", "inprogress", "refused1"):
        kit.mode(mode)
        out += [_call("host.kit.status"), _finish(_call("host.kit.rotate"))]
    assert CANARY not in json.dumps(out) and CANARY not in caplog.text
    assert SECRET not in json.dumps(out) and SECRET not in caplog.text
    assert SECRET not in " ".join(kit.argv()) and SECRET not in kit.env()
    kit.secret("x" * 200)
    try:
        kit_host.read_secret()
    except kit_host.KitFailure as exc:
        assert "x" * 20 not in repr(exc) and "x" * 20 not in exc.message


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


def test_a_refusal_is_not_retried_or_worked_around(kit):
    kit.mode("refused1")
    _call("host.kit.status")
    assert kit.argv() == [f"host status {SECRET_FLAGS}"]


def test_ok_false_with_exit_zero_is_a_failure_with_the_kit_code(kit):
    kit.mode("failzero")
    data = _call("host.kit.status")["error"]["data"]
    assert (data["code"], data["kit_code"], data["next_action"]) == ("failed", "github_unreachable", "sign_in_github")


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


def test_an_old_kit_without_the_host_subcommand_is_unsupported(kit):
    kit.mode("oldkit")
    data = _call("host.kit.status")["error"]["data"]
    assert data["code"] == "kit_unsupported" and data["subcommand"] == "status"


def test_secret_in_a_kit_body_is_redacted(kit, monkeypatch):
    monkeypatch.setattr(kit_host, "_execute", lambda name, argv, timeout, secret=None: (
        1, json.dumps({"ok": False, "code": "x", "message": f"bad {CANARY} {SECRET}", "next": {"action": CANARY}}), ""))
    data = _call("host.kit.status")["error"]["data"]
    assert CANARY not in json.dumps(data) and SECRET not in json.dumps(data)
