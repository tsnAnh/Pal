"""A leaked ``HERMES_EXEC_ASK`` never parks a command or puts it to a prompt.

When ``HERMES_EXEC_ASK`` leaks into a classic CLI process (historically via ``import gateway.run`` setting the
flag at module import), the guards used to return ``pending_approval`` with no notify listener. Nothing asks
now: the command runs, the CLI callback is never called, and no pending result is produced.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from tools.approval import check_all_command_guards, check_execute_code_guard
from tools.terminal_tool import set_approval_callback


REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(autouse=True)
def _clean_approval_env(monkeypatch):
    for key in ("HERMES_EXEC_ASK", "HERMES_GATEWAY_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_CRON_SESSION"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    set_approval_callback(None)
    yield
    set_approval_callback(None)


@pytest.mark.parametrize("interactive", [True, False])
@pytest.mark.parametrize("guard,payload", [
    (check_all_command_guards, "rm -rf /tmp/testdir"),
    (check_execute_code_guard, "print('hi')"),
])
def test_leaked_exec_ask_runs_the_call_and_never_calls_the_cli_callback(monkeypatch, guard, payload, interactive):
    monkeypatch.setenv("HERMES_EXEC_ASK", "1")
    if not interactive:
        monkeypatch.delenv("HERMES_INTERACTIVE")
    calls = []
    set_approval_callback(lambda command, description, **kwargs: calls.append(command) or "deny")

    result = guard(payload, "local")

    assert calls == []
    assert result == {"approved": True, "message": None}


def test_platform_marker_leak_without_exec_ask_runs_the_call(monkeypatch):
    monkeypatch.setenv("HERMES_SESSION_PLATFORM", "telegram")
    calls = []
    set_approval_callback(lambda command, description, **kwargs: calls.append(command) or "deny")

    assert check_execute_code_guard("print('marker')", "local") == {"approved": True, "message": None}
    assert calls == []


class TestGatewayRunImportDoesNotSetExecAsk:
    def test_importing_gateway_run_does_not_set_exec_ask(self, tmp_path):
        """Incidental imports must not poison CLI ask-mode process-wide."""
        script = rf"""
import os, sys
os.environ.pop("HERMES_EXEC_ASK", None)
sys.path.insert(0, {str(REPO_ROOT)!r})
# Avoid starting the gateway; only import the module for _gateway_runner_ref
# style side imports.
import gateway.run  # noqa: F401
print("EXEC_ASK=" + repr(os.environ.get("HERMES_EXEC_ASK")))
"""
        hermes_home = tmp_path / "import-test-home"
        proc = subprocess.run(
            [sys.executable, "-c", script],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "HERMES_HOME": str(hermes_home),
            },
            timeout=60,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert "EXEC_ASK=None" in proc.stdout, proc.stdout + proc.stderr
