"""A command the hardline scan could not read to the end is never waved through unattended.

Benign padding (a few hundred `v=$(grep -o "[^\\"]*" f)` lines) runs the hardline scan out of
budget before it reaches a later command position. The verb there must still hard-refuse (a
linear fallback over every possible command start), and what is left (the "too complex to scan"
finding) is refused where nobody can answer, even in cron / unattended approve-mode. Command
strings are only passed to the detectors, never run.
"""
import pytest

from tools import approval_context
from tools.approval import check_all_command_guards, check_dangerous_command
from tools.approval_detection import detect_hardline_command, hardline_scan_incomplete

SESSION = "scan-incomplete-human-only"
GREP = 'v=$(grep -o "[^\\"]*" f)'
BEAR_800 = "\n".join(rf'v=$(grep -o "\"f{i}\":\"[^\"]*\"" out.json)' if i % 2 == 0 else f'echo "step {i}"'
                     for i in range(800))
TEKNIUM_175 = "\n".join(['if [ -f "$f" ]; then v=$(grep -o "name=\\"[^\\"]*\\"" "$f" | head -1); '
                         'echo "$(date) $v" >> log.txt; fi'] * 175)
GREP_500 = "\n".join([GREP] * 500)
FORK_BOMB = ":()" + "{ :|:& };:"

# The reviewer's matrix: verbs at a `;` / `(` / `{` / `sudo` / `sh -c` / compound-keyword position
# that the budgeted scan never reached.
PADDED_HARDLINE = [
    pytest.param(800, "true; reboot", id="semicolon-reboot-800"),
    pytest.param(800, "(reboot)", id="subshell-reboot-800"),
    pytest.param(800, "{ reboot; }", id="brace-reboot-800"),
    pytest.param(800, "if true; then reboot; fi", id="then-reboot-800"),
    pytest.param(950, "sudo reboot", id="sudo-reboot-950"),
    pytest.param(950, FORK_BOMB, id="fork-bomb-950"),
    pytest.param(950, 'sh -c "mkfs.ext4 /dev/sda"', id="sh-c-mkfs-950"),
    pytest.param(950, "bash -c 'rm -rf /'", id="bash-c-rm-root-950"),
]


def _padded(lines: int, tail: str) -> str:
    return "\n".join([GREP] * lines + [tail])


@pytest.fixture
def gate(monkeypatch):
    """Interactive CLI with an isolated session."""
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    monkeypatch.setenv("HERMES_SESSION_KEY", SESSION)
    for name in ("HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK", "HERMES_CRON_SESSION"):
        monkeypatch.delenv(name, raising=False)
    token = approval_context.set_current_session_key(SESSION)
    yield
    approval_context.reset_current_session_key(token)


@pytest.mark.parametrize("lines,tail", PADDED_HARDLINE)
def test_a_hardline_verb_after_budget_tripping_padding_still_hard_refuses(lines, tail, gate):
    command = _padded(lines, tail)
    assert hardline_scan_incomplete(command)
    assert detect_hardline_command(command)[0] is True
    result = check_all_command_guards(command, "local")
    assert result["hardline"] is True and result["approved"] is False


@pytest.mark.parametrize("guard", [check_all_command_guards, check_dangerous_command])
def test_cron_approve_mode_refuses_an_unread_command(guard, gate, monkeypatch):
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    monkeypatch.setattr(approval_context, "_get_cron_approval_mode", lambda: "approve")
    result = guard(BEAR_800 + "\nrm -rf build/", "local")
    assert result["approved"] is False and "no human is present" in result["message"]
    assert guard("rm -rf build/", "local")["approved"] is True


@pytest.mark.parametrize("guard", [check_all_command_guards, check_dangerous_command])
def test_single_query_approve_mode_refuses_an_unread_command(guard, gate, monkeypatch):
    monkeypatch.setenv("HERMES_SINGLE_QUERY_SESSION", "1")
    monkeypatch.setattr(approval_context, "_get_single_query_approval_mode", lambda: "approve")
    result = guard(GREP_500, "local")
    assert result["approved"] is False and "too long or complex" in result["message"]
    assert guard("rm -rf build/", "local")["approved"] is True


@pytest.mark.parametrize("command", [GREP_500, BEAR_800 + "\nrm -rf build/"], ids=["grep-500", "bear-800-rm"])
def test_an_unread_command_runs_where_somebody_is_present(command, gate):
    assert check_all_command_guards(command, "local") == {"approved": True, "message": None}


@pytest.mark.parametrize("command", [TEKNIUM_175, GREP_500], ids=["teknium-175", "grep-500"])
def test_ordinary_long_scripts_are_not_hard_blocked(command, gate):
    assert detect_hardline_command(command) == (False, None)
    assert check_all_command_guards(command, "local")["approved"] is True
