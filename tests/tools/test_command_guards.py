"""Tests for check_all_command_guards() — the combined floor + dangerous-command guard."""

import os
from unittest.mock import MagicMock

import pytest

from tools.approval import check_all_command_guards
from tools.terminal_tool import set_approval_callback


@pytest.fixture(autouse=True)
def _clean_state():
    """Clear relevant env vars between tests."""
    saved = {}
    for k in ("HERMES_INTERACTIVE", "HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK"):
        if k in os.environ:
            saved[k] = os.environ.pop(k)
    yield
    for k, v in saved.items():
        os.environ[k] = v
    for k in ("HERMES_INTERACTIVE", "HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK"):
        os.environ.pop(k, None)


class TestContainerSkip:
    @pytest.mark.parametrize("env_type", ["docker", "daytona", "vercel_sandbox"])
    def test_container_backend_skips_the_floors(self, env_type):
        assert check_all_command_guards("rm -rf /", env_type)["approved"] is True


class TestNothingAsks:
    @pytest.mark.parametrize("command", ["echo hello", "rm -rf /tmp", "git push --force origin main"])
    def test_an_interactive_cli_runs_the_command_without_calling_the_callback(self, command):
        os.environ["HERMES_INTERACTIVE"] = "1"
        cb = MagicMock(return_value="deny")
        set_approval_callback(cb)
        try:
            result = check_all_command_guards(command, "local")
        finally:
            set_approval_callback(None)
        assert result["approved"] is True
        cb.assert_not_called()

    def test_non_interactive_runs_the_command(self):
        assert check_all_command_guards("rm -rf /tmp/x", "local")["approved"] is True

    def test_a_hardline_command_is_refused_not_asked(self):
        os.environ["HERMES_INTERACTIVE"] = "1"
        result = check_all_command_guards("rm -rf /", "local")
        assert result["approved"] is False and result["hardline"] is True
