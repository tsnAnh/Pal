"""Regression tests for the execute_code approval-bypass cluster.

Covers the canonical fix for issues #4146, #27303, #30882, #33057:

  1. tools.thread_context.propagate_context_to_thread — propagates the agent
     turn's ContextVars AND thread-local approval/sudo callbacks into worker
     threads, and clears the callbacks on teardown.
  2. Local and remote file-RPC carry the cell's authority in real processes.
  3. tools.approval.check_execute_code_guard — the entry-point guard decision
     matrix (isolated backends, cron-deny, headless-local).
  4. tools.code_execution_env._scrub_child_env — broad HERMES_ prefix dropped,
     operational allowlist kept, DSN/WEBHOOK blocked, passthrough precedence.
"""

from __future__ import annotations

import concurrent.futures
import contextvars
import json
import threading

import pytest

from tools import approval as A
from tools import approval_detection
from tools import approval_context
from tools.thread_context import propagate_context_to_thread
from gateway.session_context import clear_session_vars, reset_session_vars, set_session_vars
from tests.tools._child_env_fixtures import child_env


# ---------------------------------------------------------------------------
# 1. Context + callback propagation helper
# ---------------------------------------------------------------------------

def test_helper_propagates_contextvar_and_approval_callback():
    from tools import terminal_tool as TT

    probe: contextvars.ContextVar[str] = contextvars.ContextVar(
        "cluster_probe", default="unset"
    )
    probe.set("parent-value")
    sentinel = object()
    TT.set_approval_callback(sentinel)
    try:
        seen: dict = {}

        def worker():
            seen["probe"] = probe.get()
            seen["cb"] = TT._get_approval_callback()

        t = threading.Thread(target=propagate_context_to_thread(worker))
        t.start()
        t.join(timeout=5)

        assert seen["probe"] == "parent-value"  # ContextVar propagated
        assert seen["cb"] is sentinel            # thread-local callback propagated
    finally:
        TT.set_approval_callback(None)


def test_helper_clears_callbacks_on_teardown():
    """A recycled worker thread must not retain the propagated callback after
    the wrapped target finishes (mirrors the GHSA-qg5c-hvr5-hjgr teardown)."""
    from tools import terminal_tool as TT

    sentinel = object()
    TT.set_approval_callback(sentinel)
    try:
        seen: dict = {}

        def first():
            seen["during"] = TT._get_approval_callback()

        def second():  # NOT wrapped — runs on the same recycled worker thread
            seen["after"] = TT._get_approval_callback()

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            ex.submit(propagate_context_to_thread(first)).result(timeout=5)
            ex.submit(second).result(timeout=5)

        assert seen["during"] is sentinel  # installed for the wrapped target
        assert seen["after"] is None       # cleared on teardown
    finally:
        TT.set_approval_callback(None)


@pytest.mark.platforms("posix")
@pytest.mark.parametrize("transport", ["local", "remote-file"])
def test_rpc_carries_authority_to_real_dispatch(child_env, monkeypatch, transport):
    import time
    import model_tools
    from tests.tools._child_env_fixtures import RunToCompletionEnv, run_code
    from tools import terminal_tool
    from tools.code_execution_tool import _run_remote_per_call

    witness = child_env / "authority.txt"

    marker = contextvars.ContextVar("rpc-authority", default="missing")
    seen = []
    original = model_tools.handle_function_call

    def dispatch(name, args, *pos, **kwargs):
        seen.append((marker.get(), terminal_tool._get_approval_callback()))
        return original(name, args, *pos, **kwargs)

    monkeypatch.setattr(model_tools, "handle_function_call", dispatch)
    code = f"from hermes_tools import read_file\nimport json\nprint(json.dumps(read_file({str(witness)!r})))"
    try:
        for turn in ("first", "second"):
            witness.write_text(f"real RPC payload {turn}\n", encoding="utf-8")
            callback = object()
            token = marker.set(turn)
            terminal_tool.set_approval_callback(callback)
            try:
                if transport == "local":
                    result = run_code(code, reset=(turn == "first"))
                else:
                    raw = json.loads(_run_remote_per_call(
                        RunToCompletionEnv(child_env), "ssh", code, "authority-test",
                        frozenset({"read_file"}), timeout=30, max_tool_calls=2, exec_start=time.monotonic()))
                    assert raw["status"] == "success", raw
                    assert raw["tool_calls_made"] == 1
                    result = json.loads(raw["output"])
                assert "content" in result, result
                assert f"real RPC payload {turn}" in result["content"]
                assert seen[-1] == (turn, callback)
            finally:
                marker.reset(token)
    finally:
        terminal_tool.set_approval_callback(None)
    assert len(seen) == 2


@pytest.mark.platforms("posix")
def test_terminal_inside_a_script_still_meets_the_command_floors(child_env, monkeypatch):
    from tests.tools._child_env_fixtures import run_code

    victim = child_env / "victim"
    victim.mkdir()
    command = f"rm -rf {victim}"
    code = f"import json\nfrom hermes_tools import terminal\nprint(json.dumps(terminal({command!r})))"
    monkeypatch.setattr(A, "_match_user_deny_rule", lambda cmd: "rm -rf *" if "victim" in cmd else None)
    result = run_code(code, enabled_tools=("terminal",))
    assert victim.is_dir(), result
    assert "approvals.deny" in json.dumps(result), result


# ---------------------------------------------------------------------------
# 3. check_execute_code_guard decision matrix
# ---------------------------------------------------------------------------

def test_guard_isolated_backend_approved():
    # Container backends already sandbox the child — no-op approve.
    assert A.check_execute_code_guard("import os", "docker")["approved"] is True


def test_guard_headless_local_approved(monkeypatch):
    # Documented #30882 limitation: no approval surface → preserve auto-run.
    monkeypatch.delenv("HERMES_GATEWAY_SESSION", raising=False)
    monkeypatch.delenv("HERMES_INTERACTIVE", raising=False)
    monkeypatch.delenv("HERMES_CRON_SESSION", raising=False)
    monkeypatch.delenv("HERMES_EXEC_ASK", raising=False)
    assert A.check_execute_code_guard("import os", "local")["approved"] is True


def test_guard_cron_deny_blocks(monkeypatch):
    monkeypatch.delenv("HERMES_CRON_SESSION", raising=False)
    monkeypatch.delenv("HERMES_GATEWAY_SESSION", raising=False)
    monkeypatch.setattr(approval_context, "_get_cron_approval_mode", lambda: "deny")
    tokens = set_session_vars(cron_session="1")
    try:
        res = A.check_execute_code_guard("import os", "local")
    finally:
        clear_session_vars(tokens)
    assert res["approved"] is False
    assert res["outcome"] == "blocked"


def test_guard_explicit_non_cron_masks_leaked_env(monkeypatch):
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    monkeypatch.delenv("HERMES_GATEWAY_SESSION", raising=False)
    monkeypatch.delenv("HERMES_INTERACTIVE", raising=False)
    monkeypatch.delenv("HERMES_EXEC_ASK", raising=False)
    monkeypatch.setattr(approval_context, "_get_cron_approval_mode", lambda: "deny")
    tokens = set_session_vars(cron_session="")
    try:
        res = A.check_execute_code_guard("import os", "local")
    finally:
        clear_session_vars(tokens)
        reset_session_vars()
    assert res["approved"] is True


def test_guard_legacy_env_cron_still_blocks(monkeypatch):
    reset_session_vars()
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    monkeypatch.delenv("HERMES_GATEWAY_SESSION", raising=False)
    monkeypatch.setattr(approval_context, "_get_cron_approval_mode", lambda: "deny")
    res = A.check_execute_code_guard("import os", "local")
    assert res["approved"] is False
    assert res["outcome"] == "blocked"


# ---------------------------------------------------------------------------
# 4. Env scrubbing (#27303)
# ---------------------------------------------------------------------------

def test_env_scrub_hermes_allowlist_and_secret_blocks():
    from tools.code_execution_env import _scrub_child_env

    env = {
        # operational allowlist → kept
        "HERMES_HOME": "/h", "HERMES_PROFILE": "p",
        "HERMES_CONFIG": "/c.yaml", "HERMES_ENV": "/e",
        "HERMES_DELEGATED_CHILD_CONTEXT": "1",
        # other HERMES_* → dropped (broad prefix removed)
        "HERMES_BASE_URL": "https://x", "HERMES_INTERACTIVE": "1",
        "HERMES_KANBAN_TASK": "t_parent",
        # secret substrings (incl. new DSN/WEBHOOK) → dropped
        "SENTRY_DSN": "https://a@s.io/1", "SLACK_WEBHOOK": "https://h/x",
        "OPENAI_API_KEY": "sk", "GITHUB_TOKEN": "ghp",
        # safe prefix → kept; uncategorized → dropped
        "PATH": "/usr/bin", "RANDOM_X": "y",
    }
    out = _scrub_child_env(env, is_passthrough=lambda _: False, is_windows=False)

    for kept in (
        "HERMES_HOME", "HERMES_PROFILE", "HERMES_CONFIG", "HERMES_ENV",
        "HERMES_DELEGATED_CHILD_CONTEXT", "PATH",
    ):
        assert kept in out, f"{kept} should be kept"
    for dropped in (
        "HERMES_BASE_URL", "HERMES_INTERACTIVE", "HERMES_KANBAN_TASK",
        "SENTRY_DSN", "SLACK_WEBHOOK", "OPENAI_API_KEY", "GITHUB_TOKEN",
        "RANDOM_X",
    ):
        assert dropped not in out, f"{dropped} should be dropped"


def test_env_scrub_passthrough_overrides_secret_block():
    """A skill/config-declared passthrough var is an explicit user opt-in and
    passes even if it matches a secret substring (precedence is intentional)."""
    from tools.code_execution_env import _scrub_child_env

    env = {"MY_SERVICE_DSN": "value"}
    out = _scrub_child_env(env, is_passthrough=lambda k: k == "MY_SERVICE_DSN",
                           is_windows=False)
    assert out.get("MY_SERVICE_DSN") == "value"


# ---------------------------------------------------------------------------
# 5. File-tool sensitive-path refusal (security B1)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 6. Env-scrub diagnosability mitigation (#27303 follow-up)
# ---------------------------------------------------------------------------
