"""Always Ask / Allow rules in the smart approval guardian, driven through the real command guard with the guardian
model stubbed at its model boundary (``agent.auxiliary_client.call_llm``) and a real config.yaml."""

from __future__ import annotations

import re
from types import SimpleNamespace

import pytest

import hermes_cli.config as hermes_config
import hermes_yaml as yaml
from tools import approval as A
from tools import approval_context
from tools import approval_rules

FLAGGED = "git push --force origin main"
UNFLAGGED = "sendmail bob@example.com"
SESSION = "approval-rules-session"


class Guardian:
    """A guardian model that reads the rules out of the prompt it was sent, as a compliant model would.

    A rule matches a command when the rule's last word appears in it. Without a matching rule it answers
    ``default`` (a cautious model: ESCALATE for flagged commands it cannot clear, APPROVE otherwise)."""

    def __init__(self):
        self.prompts: list[tuple[str, str]] = []
        self.default = "APPROVE"
        self.failure: Exception | None = None
        self.forced: str | None = None

    def __call__(self, **kwargs):
        system, user = (message["content"] for message in kwargs["messages"])
        self.prompts.append((system, user))
        if self.failure is not None:
            raise self.failure
        command = re.search(r"<command>\n(.*?)\n</command>", user, re.DOTALL).group(1)
        answer = self.forced or self._judge(system, command)
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=answer), finish_reason="stop")])

    def _judge(self, system: str, command: str) -> str:
        for heading, word in (("Always Ask rules", "ASK"), ("Allow rules", "ALLOW")):
            block = re.search(rf"{heading}[^\n]*\n((?:\d+\. .*\n?)+)", system)
            for rule in (block.group(1).strip().splitlines() if block else []):
                if rule.split()[-1] in command:
                    return word
        return self.default

    @property
    def calls(self) -> int:
        return len(self.prompts)


class Human:
    def __init__(self):
        self.asked: list[dict] = []
        self.choice = "once"

    def __call__(self, command, description, **kwargs):
        self.asked.append({"command": command, "description": description, **kwargs})
        return self.choice


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / "hermes"
    path.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(path))
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    for name in ("HERMES_GATEWAY_SESSION", "HERMES_CRON_SESSION", "HERMES_EXEC_ASK", "HERMES_YOLO_MODE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(A, "_YOLO_MODE_FROZEN", False)
    hermes_config._LOAD_CONFIG_CACHE.clear()
    token = approval_context.set_current_session_key(SESSION)
    with A._lock:
        A._permanent_set().clear()
        A._session_approved.pop(SESSION, None)
    yield path
    approval_context.reset_current_session_key(token)
    with A._lock:
        A._permanent_set().clear()
        A._session_approved.pop(SESSION, None)
    hermes_config._LOAD_CONFIG_CACHE.clear()


def configure(home, *, mode="smart", ask=(), allow=(), deny=()):
    def rules(texts):
        return [{"id": f"r{index}", "text": text, "created_at": "2026-01-01T00:00:00Z"} for index, text in enumerate(texts)]
    approvals = {"mode": mode, "deny": list(deny), "rules": {"ask": rules(ask), "allow": rules(allow)}}
    (home / "config.yaml").write_text(yaml.safe_dump({"approvals": approvals}), encoding="utf-8")
    hermes_config._LOAD_CONFIG_CACHE.clear()


@pytest.fixture
def guardian(monkeypatch):
    stub = Guardian()
    monkeypatch.setattr("agent.auxiliary_client.call_llm", stub)
    return stub


@pytest.fixture
def human():
    return Human()


def guard(command, human):
    return A.check_all_command_guards(command, "local", approval_callback=human)


def test_an_ask_rule_stops_an_unflagged_command_the_guardian_would_have_approved(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    assert guard("git status", human)["approved"] is True and human.asked == []

    result = guard(UNFLAGGED, human)

    assert result["approved"] is True and result.get("user_approved") is True
    assert len(human.asked) == 1
    assert approval_rules.ASK_DESCRIPTION in human.asked[0]["description"]


def test_an_ask_is_one_operation_and_a_deny_blocks(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    guard(UNFLAGGED, human)
    assert human.asked[0]["allow_permanent"] is False and human.asked[0]["allow_session"] is False
    guard(UNFLAGGED, human)
    assert len(human.asked) == 2

    human.choice = "deny"
    blocked = guard(UNFLAGGED, human)
    assert blocked["approved"] is False and "BLOCKED" in blocked["message"]


def test_an_always_answer_to_an_ask_persists_nothing(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    human.choice = "always"
    guard(UNFLAGGED, human)
    assert not A.is_approved(SESSION, approval_rules.ask_pattern_key(UNFLAGGED))
    guard(UNFLAGGED, human)
    assert len(human.asked) == 2


def test_a_flagged_command_with_a_matching_ask_rule_asks_where_smart_would_have_approved(home, guardian, human):
    configure(home)
    assert guard(FLAGGED, human)["smart_approved"] is True and human.asked == []

    configure(home, ask=["Ask before running push"])
    result = guard(FLAGGED, human)

    assert result.get("smart_approved") is None and result["approved"] is True
    assert len(human.asked) == 1 and human.asked[0]["allow_permanent"] is False


def test_an_ask_rule_beats_a_session_approval_and_the_permanent_allowlist(home, guardian, human):
    configure(home, ask=["Ask before running sendmail", "Ask before running push"])
    A.approve_permanent("sendmail *")
    pattern_key = A.detect_dangerous_command(FLAGGED)[1]
    A.approve_session(SESSION, pattern_key)

    guard(UNFLAGGED, human)
    guard(FLAGGED, human)

    assert len(human.asked) == 2


def test_cached_approvals_still_apply_to_commands_no_ask_rule_matches(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    A.approve_session(SESSION, A.detect_dangerous_command(FLAGGED)[1])
    assert guard(FLAGGED, human)["approved"] is True and human.asked == []


def test_an_allow_rule_lets_a_flagged_command_through_without_asking(home, guardian, human):
    guardian.default = "ESCALATE"
    configure(home)
    guard(FLAGGED, human)
    assert len(human.asked) == 1

    human.asked.clear()
    configure(home, allow=["Allow running push"])
    result = guard(FLAGGED, human)

    assert result["approved"] is True and result["rule_allowed"] is True and human.asked == []


def test_an_ask_rule_beats_an_allow_rule_that_also_matches(home, guardian, human):
    configure(home, ask=["Ask before running push"], allow=["Allow running push"])
    guard(FLAGGED, human)
    assert len(human.asked) == 1


def test_a_deny_glob_beats_an_allow_rule_and_never_reaches_the_guardian(home, guardian, human):
    configure(home, allow=["Allow running push"], deny=["git push --force*"])

    result = guard(FLAGGED, human)

    assert result["approved"] is False and result["user_deny"] is True
    assert guardian.calls == 0 and human.asked == []


def test_a_hardline_block_beats_an_allow_rule(home, guardian, human):
    configure(home, allow=["Allow running rm"])
    result = guard("rm -rf /", human)
    assert result["approved"] is False
    assert guardian.calls == 0 and human.asked == []


def test_the_guardian_cannot_ask_or_allow_for_rules_the_user_never_wrote(home, guardian, human):
    configure(home)
    guardian.forced = "ALLOW"
    guard(FLAGGED, human)
    assert len(human.asked) == 1
    guardian.forced = "ASK"
    guard(FLAGGED, human)
    assert len(human.asked) == 2 and human.asked[1]["allow_permanent"] is True


def test_an_allow_answer_needs_an_allow_rule_and_an_ask_answer_an_ask_rule(home, guardian, human):
    configure(home, allow=["Allow running push"])
    guardian.forced = "ASK"
    assert approval_rules.accepted_verdicts(approval_rules.current()) == {
        "APPROVE": "approve", "DENY": "deny", "ALLOW": "allow"}
    guard(FLAGGED, human)
    assert len(human.asked) == 1 and approval_rules.ASK_DESCRIPTION not in human.asked[0]["description"]


def test_a_guardian_that_fails_asks_the_human_for_an_unflagged_command_when_ask_rules_exist(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    guardian.failure = RuntimeError("provider down")
    assert guard("git status", human)["approved"] is True
    assert len(human.asked) == 1


def test_a_guardian_deny_of_an_unflagged_command_stops_for_the_human(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    guardian.forced = "DENY"
    guard("git status", human)
    assert len(human.asked) == 1


def test_without_ask_rules_an_unflagged_command_never_reaches_the_guardian(home, guardian, human):
    configure(home, allow=["Allow running push"])
    assert guard("git status", human)["approved"] is True
    assert guardian.calls == 0 and human.asked == []


def test_one_command_costs_one_guardian_call(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"])
    guard(FLAGGED, human)
    guard(UNFLAGGED, human)
    assert guardian.calls == 2


def test_rules_only_apply_under_auto_review(home, guardian, human):
    configure(home, mode="manual", ask=["Ask before running sendmail"], allow=["Allow running push"])
    assert guard(UNFLAGGED, human)["approved"] is True and human.asked == []
    guard(FLAGGED, human)
    assert len(human.asked) == 1 and guardian.calls == 0


def test_an_unattended_session_is_not_reviewed_against_rules(home, guardian, human, monkeypatch):
    monkeypatch.delenv("HERMES_INTERACTIVE")
    configure(home, ask=["Ask before running sendmail"])
    assert guard(UNFLAGGED, human)["approved"] is True
    assert guardian.calls == 0 and human.asked == []


def test_rules_ride_the_guardians_system_prompt_and_never_its_user_prompt(home, guardian, human):
    configure(home, ask=["Ask before running sendmail"], allow=["Allow running push"])
    guard(FLAGGED, human)

    system, user = guardian.prompts[0]
    assert "1. Ask before running sendmail" in system and "1. Allow running push" in system
    assert "sendmail" not in user and "Allow running push" not in user
    assert user.rstrip().endswith("APPROVE, DENY, ESCALATE, ASK, or ALLOW")


def test_the_guardian_prompt_is_untouched_when_no_rules_exist(home, guardian, human):
    configure(home)
    guard(FLAGGED, human)
    system, user = guardian.prompts[0]
    assert "Approval rules" not in system and "ASK" not in system
    assert user.rstrip().endswith("APPROVE, DENY, or ESCALATE")


def test_a_rule_edit_is_picked_up_by_the_next_command_without_a_restart(home, guardian, human):
    configure(home)
    guard(UNFLAGGED, human)
    assert human.asked == []
    configure(home, ask=["Ask before running sendmail"])
    guard(UNFLAGGED, human)
    assert len(human.asked) == 1
