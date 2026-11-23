"""A command the scanners run out of budget on is not a hardline refusal.

Hardline refusals stay for the real limits (size, segment count, real ``$(`` nesting) and for any
hardline rule, whether the full scan reached it or only the linear fallback did (see
test_approval_scan_incomplete_human_only.py). Where somebody is present the command just runs; where
nobody can answer, it is refused as unread.
"""
import pytest

from tools import approval_context
from tools.approval import check_all_command_guards
from tools.approval_detection import (
    _PARSER_LIMIT_DESCRIPTION, _SCAN_INCOMPLETE_DESCRIPTION, detect_dangerous_command, detect_hardline_command)

SESSION = "scan-budget-session"
# Every `\"` inside `$(…)` leaves a `$(` open in the escape-stripped text, so a few hundred such
# lines run the scanners out of budget although bash nests none of them.
BEAR_800 = [rf'v=$(grep -o "\"f{i}\":\"[^\"]*\"" out.json)' if i % 2 == 0 else f'echo "step {i}"'
            for i in range(800)]
TEKNIUM_175 = "\n".join(['if [ -f "$f" ]; then v=$(grep -o "name=\\"[^\\"]*\\"" "$f" | head -1); '
                         'echo "$(date) $v" >> log.txt; fi'] * 175)
GREP_500 = "\n".join(['v=$(grep -o "[^\\"]*" f)'] * 500)


@pytest.fixture
def manual_cli(monkeypatch):
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    monkeypatch.setenv("HERMES_SESSION_KEY", SESSION)
    for name in ("HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK", "HERMES_CRON_SESSION"):
        monkeypatch.delenv(name, raising=False)
    token = approval_context.set_current_session_key(SESSION)
    yield
    approval_context.reset_current_session_key(token)


def test_a_long_script_that_runs_out_of_scan_budget_runs_where_somebody_is_present(manual_cli):
    command = "\n".join([*BEAR_800, "rm -rf build/"])
    result = check_all_command_guards(command, "local")
    assert result == {"approved": True, "message": None}


def test_an_unread_command_is_refused_where_nobody_can_answer(manual_cli, monkeypatch):
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    monkeypatch.setattr(approval_context, "_get_cron_approval_mode", lambda: "approve")
    result = check_all_command_guards("\n".join([*BEAR_800, "rm -rf build/"]), "local")
    assert result["approved"] is False and not result.get("hardline")
    assert result["pattern_key"] == _SCAN_INCOMPLETE_DESCRIPTION
    assert "too long or complex" in result["message"]


@pytest.mark.parametrize("command", [TEKNIUM_175, GREP_500], ids=["teknium-175-lines", "grep-500"])
def test_ordinary_scripts_over_the_budget_are_not_hard_blocked(command, manual_cli):
    assert detect_hardline_command(command) == (False, None)
    assert detect_dangerous_command(command)[1] == _SCAN_INCOMPLETE_DESCRIPTION
    result = check_all_command_guards(command, "local")
    assert result["approved"] is True and not result.get("hardline")


def test_real_nesting_still_hard_refuses(manual_cli):
    command = "echo " + "$(" * 40 + "x" + ")" * 40
    assert detect_hardline_command(command) == (True, _PARSER_LIMIT_DESCRIPTION)
    result = check_all_command_guards(command, "local")
    assert result["hardline"] is True and result["approved"] is False


@pytest.mark.parametrize("tail", ["rm -rf /", "bash -c 'rm -rf /'", "reboot"])
def test_a_hardline_verb_found_before_the_budget_ran_out_still_hard_refuses(tail, manual_cli):
    command = "\n".join([*BEAR_800, tail])
    assert detect_hardline_command(command)[0] is True
    result = check_all_command_guards(command, "local")
    assert result["hardline"] is True and result["approved"] is False
