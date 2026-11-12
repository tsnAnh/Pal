from __future__ import annotations

import json
import logging
import subprocess
import sys
import textwrap
import time
import types

import pytest

from tests.waiting import wait_until
from tools import auth_required
from tui_gateway import github_signin, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

CANARY = "ghp_CANARYTOKEN0123456789abcdefghijklmnop"
HOSTS_PATH_CANARY = "/canary/gh/hosts.yml"

FAKE_GH = textwrap.dedent(f"""
    import os, sys, time
    sys.stderr.write("! First copy your one-time code: ABCD-1234\\n")
    sys.stderr.write("Open this URL to continue in your web browser: https://github.com/login/device\\n")
    sys.stderr.write("token {CANARY} stored at {HOSTS_PATH_CANARY}\\n")
    sys.stderr.flush()
    done = os.environ["FAKE_GH_DONE"]
    for _ in range(600):
        if os.path.exists(done):
            sys.exit(int(open(done).read() or 0))
        time.sleep(0.05)
""")


class Gh:
    def __init__(self, signed_in=True, protocol="https", host_key=True, login="octocat"):
        self.signed_in, self.protocol, self.host_key, self.login = signed_in, protocol, host_key, login
        self.calls: list[list[str]] = []

    def run(self, argv):
        self.calls.append(argv)
        if argv[:3] == ["gh", "auth", "status"]:
            if not self.signed_in:
                return 1, "You are not logged into any GitHub hosts. To get started with GitHub CLI, please run:  gh auth login"
            return 0, f"github.com\n  ✓ Logged in to github.com account {self.login} (keyring)\n  - Token: gho_****"
        if argv[:3] == ["gh", "config", "get"]:
            return 0, self.protocol + "\n"
        if argv[0] == "ssh-keygen":
            return (0, "# Host github.com found: line 1\n") if self.host_key else (1, "")
        return 0, ""


@pytest.fixture
def gh(monkeypatch):
    fake = Gh()
    monkeypatch.setattr(github_signin, "_run", fake.run)
    return fake


@pytest.fixture
def fake_process(tmp_path, monkeypatch):
    script, done = tmp_path / "fake_gh.py", tmp_path / "done"
    script.write_text(FAKE_GH)
    real_popen = subprocess.Popen
    launched = []

    def popen(argv, **kwargs):
        kwargs["env"] = {**kwargs["env"], "FAKE_GH_DONE": str(done)}
        launched.append((argv, kwargs["env"]))
        return real_popen([sys.executable, str(script)], **kwargs)

    monkeypatch.setattr(github_signin.subprocess, "Popen", popen)
    yield types.SimpleNamespace(launched=launched, finish=lambda code=0: done.write_text(str(code)))
    github_signin.cancel_all()


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def test_status_signed_in(gh):
    result = _call("github.status")["result"]
    assert result == {"signed_in": True, "login": "octocat", "host": "github.com", "git_protocol": "https",
                      "ssh_host_key_known": True, "problems": []}


def test_status_signed_out_offers_signin(gh):
    gh.signed_in = False
    result = _call("github.status")["result"]
    assert result["signed_in"] is False and result["login"] is None
    assert [(p["id"], p["fix"]) for p in result["problems"]] == [("gh_signed_out", "github.signin")]


def test_ssh_with_unknown_host_key_is_a_problem(gh):
    gh.protocol, gh.host_key = "ssh", False
    result = _call("github.status")["result"]
    assert result["git_protocol"] == "ssh" and result["ssh_host_key_known"] is False
    assert [(p["id"], p["fix"]) for p in result["problems"]] == [
        ("git_ssh_unknown_host", "github.git_protocol.fix")]


def test_ssh_with_known_host_key_is_healthy(gh):
    gh.protocol = "ssh"
    assert _call("github.status")["result"]["problems"] == []


def test_unreadable_fields_degrade_without_crashing(monkeypatch):
    monkeypatch.setattr(github_signin, "_run", lambda argv: None)
    result = _call("github.status")["result"]
    assert (result["signed_in"], result["login"], result["git_protocol"], result["ssh_host_key_known"]) == (
        False, None, "unset", False)


def test_fix_sets_git_and_both_gh_levels_and_is_idempotent(gh):
    first = _call("github.git_protocol.fix")["result"]
    expected = [
        ["git", "config", "--global", "url.https://github.com/.insteadOf", "git@github.com:"],
        ["gh", "config", "set", "git_protocol", "https"],
        ["gh", "config", "set", "git_protocol", "https", "-h", "github.com"],
    ]
    writes = [c for c in gh.calls if c[:2] in (["git", "config"], ["gh", "config"]) and "get" not in c]
    assert writes == expected
    gh.calls.clear()
    assert _call("github.git_protocol.fix")["result"] == first
    assert [c for c in gh.calls if c in expected] == expected


def test_fix_failure_is_a_plain_error(monkeypatch):
    monkeypatch.setattr(github_signin, "_run", lambda argv: (1, ""))
    error = _call("github.git_protocol.fix")["error"]
    assert error["code"] == 5301 and "HTTPS" in error["message"]


def test_signin_state_machine(gh, fake_process):
    started = _call("github.signin.start")["result"]
    assert started["user_code"] == "ABCD-1234"
    assert started["verification_uri"] == "https://github.com/login/device"
    assert started["interval"] == 5 and 0 < started["expires_in"] <= 900
    argv, env = fake_process.launched[0]
    assert argv == ["gh", "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web",
                    "--skip-ssh-key"]
    assert env["BROWSER"] == "true"
    assert _call("github.signin.start")["result"]["session_id"] == started["session_id"]
    assert len(fake_process.launched) == 1
    sid = {"session_id": started["session_id"]}
    assert _call("github.signin.poll", sid)["result"] == {"state": "pending"}
    fake_process.finish(0)
    deadline = time.monotonic() + 10
    while True:
        polled = _call("github.signin.poll", sid)["result"]
        if polled["state"] != "pending" or time.monotonic() > deadline:
            break
        time.sleep(0.05)
    assert polled["state"] == "signed_in" and polled["login"] == "octocat"
    assert ["gh", "config", "set", "git_protocol", "https", "-h", "github.com"] in gh.calls


def test_signin_failed_exit_is_failed(gh, fake_process):
    sid = {"session_id": _call("github.signin.start")["result"]["session_id"]}
    fake_process.finish(1)
    deadline = time.monotonic() + 10
    while (polled := _call("github.signin.poll", sid)["result"])["state"] == "pending" and time.monotonic() < deadline:
        time.sleep(0.05)
    assert polled["state"] == "failed" and polled["message"]


def test_cancel_stops_the_gh_process(gh, fake_process):
    started = _call("github.signin.start")["result"]
    proc = github_signin._current.proc
    assert _call("github.signin.cancel", {"session_id": started["session_id"]})["result"] == {"ok": True}
    assert proc.poll() is not None
    assert _call("github.signin.poll", {"session_id": started["session_id"]})["result"]["state"] == "failed"


def test_expiry_kills_the_process(gh, fake_process, monkeypatch):
    started = _call("github.signin.start")["result"]
    proc = github_signin._current.proc
    monkeypatch.setattr(github_signin, "_clock", lambda: time.monotonic() + 10_000)
    assert _call("github.signin.poll", {"session_id": started["session_id"]})["result"]["state"] == "expired"
    assert proc.poll() is not None


def test_gateway_stop_hook_leaves_no_orphan(gh, fake_process):
    _call("github.signin.start")
    proc = github_signin._current.proc
    github_signin.cancel_all()
    assert proc.poll() is not None


def test_no_secret_in_any_response_or_log(gh, fake_process, caplog):
    caplog.set_level(logging.DEBUG)
    started = _call("github.signin.start")["result"]
    fake_process.finish(0)
    sid = {"session_id": started["session_id"]}
    wait_until(lambda: github_signin._current.proc.poll() is not None)
    seen = [started, _call("github.status")["result"], _call("github.signin.poll", sid)["result"],
            _call("github.git_protocol.fix")["result"]]
    blob = json.dumps(seen) + caplog.text
    assert CANARY not in blob and HOSTS_PATH_CANARY not in blob and "gho_" not in blob
    assert "ABCD-1234" not in caplog.text


def test_subprocess_env_keeps_host_xdg_and_drops_tokens(monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", "/home/host/.config")
    monkeypatch.setenv("GH_TOKEN", CANARY)
    monkeypatch.setenv("GITHUB_TOKEN", CANARY)
    monkeypatch.setattr("tools.bot_desktop.runtime.published_env",
                        lambda: {"DISPLAY": ":20", "XDG_CONFIG_HOME": "/run/hermes/bot-desktop/config"})
    env = github_signin.host_env()
    assert env["XDG_CONFIG_HOME"] == "/home/host/.config"
    assert not {"GH_TOKEN", "GITHUB_TOKEN"} & set(env)
    assert CANARY not in json.dumps(env)


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    names = {"github.status", "github.signin.start", "github.signin.poll", "github.signin.cancel",
             "github.git_protocol.fix"}
    assert names <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in names)


def test_worker_and_capability_less_connections_cannot_reach_github():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    assert not legacy_fallback_allowed(worker, "github.status")
    assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), "github.status")
    assert legacy_fallback_allowed(owner, "github.status")


def test_secondary_profile_ticket_is_refused(gh):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        for method, params in (("github.status", {}), ("github.signin.start", {}),
                               ("github.git_protocol.fix", {}),
                               ("github.signin.poll", {"session_id": "x"}), ("github.signin.cancel", {"session_id": "x"})):
            assert _call(method, params)["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert gh.calls == []


@pytest.mark.parametrize("exit_code", [4, 1])
def test_gh_signed_out_message_raises_the_sign_in_prompt_and_output_is_unchanged(exit_code):
    output = ("To get started with GitHub CLI, please run:  gh auth login\n"
              "Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.")
    result = json.dumps({"output": output, "exit_code": exit_code})
    need = auth_required.detect("terminal", {"command": "gh pr list"}, result)
    assert need == auth_required.AuthNeed("github", "missing", flow="device_code")
    assert json.loads(result)["output"] == output
