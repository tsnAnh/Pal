import asyncio
import json

import pytest

from gateway import auth_flows
from tools import auth_required
from tools.skills_tool_setup import _get_required_environment_variables

CANARY = "canary-app-password-7391"


V2_BACKTRACE = """

Backtrace:
   0: <unknown>
   1: <unknown>
   2: __libc_start_call_main
             at ./csu/../sysdeps/nptl/libc_start_call_main.h:58:16

Suggestions:
 - Run with --log-level to enable more verbose logs"""
V2_SECRET_COMMAND_FAILED = "Error: Secret command error: " + V2_BACKTRACE
V2_SERVER_REJECTED = "Error: IMAP AUTHENTICATE PLAIN failed: NO Authentication failed." + V2_BACKTRACE
V2_SMTP_REJECTED = "Error: SMTP AUTH PLAIN failed: rejected 535 5.7.8 Authentication credentials invalid" + V2_BACKTRACE
LIST = {"command": "himalaya mailbox list"}


def terminal_result(output, code):
    return json.dumps({"output": output, "exit_code": code})


@pytest.mark.parametrize("output", [
    "Error: cannot authenticate to IMAP server: AUTHENTICATIONFAILED Invalid credentials",
    "NO [AUTHENTICATIONFAILED] Authentication failed.",
    "A1 NO LOGIN failed",
    "smtp: 535 5.7.8 Username and Password not accepted",
    "535 Authentication credentials invalid",
    "Application-specific password required",
])
def test_auth_failure_variants_become_one_email_need(output):
    need = auth_required.detect("terminal", {"command": "himalaya envelope list"}, terminal_result(output, 1))
    assert need == auth_required.AuthNeed("email:himalaya", "expired", "api_key")


@pytest.mark.parametrize("command,output,code", [
    ("himalaya envelope list", "Authentication failed", 0),
    ("himalaya envelope list", "connection timed out", 1),
    ("ls", "Authentication failed", 1),
    ("echo himalaya", "Authentication failed", 1),
])
def test_other_outputs_never_trigger_the_popup(command, output, code):
    assert auth_required.detect("terminal", {"command": command}, terminal_result(output, code)) is None


def test_failed_credential_prompts_once_and_does_not_loop(monkeypatch):
    prompts = []
    from gateway import auth_prompts
    monkeypatch.setattr(auth_prompts, "call_from_thread",
                        lambda home, need, bot: prompts.append(need) or auth_prompts.Resolution.SIGNED_IN)
    failing = terminal_result("Authentication failed", 1)
    calls = []
    out = auth_required.resolve("terminal", {"command": "himalaya envelope list"}, failing,
                                lambda: calls.append(1) or failing)
    assert len(prompts) == 1 and len(calls) == 1
    assert json.loads(out)["error_type"] == "auth_failed"


def test_declined_popup_is_not_retried(monkeypatch):
    from gateway import auth_prompts
    monkeypatch.setattr(auth_prompts, "call_from_thread", lambda *a: auth_prompts.Resolution.DECLINED)
    calls = []
    out = auth_required.resolve("terminal", {"command": "himalaya envelope list"},
                                terminal_result("Authentication failed", 1), lambda: calls.append(1))
    assert calls == [] and json.loads(out)["error_type"] == "auth_declined"


def test_missing_binary_is_typed_and_never_opens_a_popup(monkeypatch):
    from gateway import auth_prompts
    monkeypatch.setattr(auth_prompts, "call_from_thread", lambda *a: pytest.fail("popup"))
    out = auth_required.resolve("terminal", {"command": "himalaya folder list"},
                                terminal_result("bash: himalaya: command not found", 127), lambda: None)
    body = json.loads(out)
    assert body["error_type"] == "himalaya_not_installed"
    assert "terminal" not in body["error"].replace("open a terminal", "")


def test_skill_declares_the_password_so_the_masked_prompt_fires():
    from pathlib import Path
    from agent.skill_utils import parse_frontmatter
    text = (Path(__file__).parents[2] / "skills/email/himalaya/SKILL.md").read_text()
    frontmatter, _ = parse_frontmatter(text)
    names = [e["name"] for e in _get_required_environment_variables(frontmatter)]
    assert names == ["HIMALAYA_PASSWORD"]
    assert "auth.raw" not in text and "printenv HIMALAYA_PASSWORD" in text


def test_email_flow_stores_only_in_env_and_rejects_blank(monkeypatch):
    saved = {}
    monkeypatch.setattr("hermes_cli.config.save_env_value_secure", lambda k, v: saved.update({k: v}))
    flow = auth_flows.flow_for(None, "email:himalaya")
    assert flow.kind == "api_key"
    assert asyncio.run(flow.store("  ")) is False and saved == {}
    assert asyncio.run(flow.store(CANARY)) is True
    assert saved == {"HIMALAYA_PASSWORD": CANARY}


def test_canary_not_in_failure_text_or_display_name():
    need = auth_required.AuthNeed("email:himalaya", "expired", "api_key")
    out = auth_required._failure("failed", need, "bot", "auth_failed")
    assert CANARY not in out and auth_required.service_display_name(need.service) == "Email"


def _load_real_skill(tmp_path, monkeypatch, callback):
    import shutil
    from pathlib import Path
    from tools import env_passthrough
    dest = tmp_path / "email" / "himalaya"
    shutil.copytree(Path(__file__).parents[2] / "skills/email/himalaya", dest)
    monkeypatch.setattr("tools.skills_tool.SKILLS_DIR", tmp_path)
    monkeypatch.setattr(env_passthrough, "_allowed_env_vars", set())
    from tools.skills_tool import bind_turn_secret_capture, skill_view
    with bind_turn_secret_capture(callback):
        return json.loads(skill_view(name="himalaya"))


def test_loading_himalaya_without_a_password_opens_the_masked_prompt(tmp_path, monkeypatch):
    monkeypatch.delenv("HIMALAYA_PASSWORD", raising=False)
    asked = []

    def callback(name, prompt, metadata=None):
        asked.append((name, metadata))
        return {"success": False, "skipped": True, "stored_as": name, "validated": False}

    _load_real_skill(tmp_path, monkeypatch, callback)
    assert [name for name, _ in asked] == ["HIMALAYA_PASSWORD"]
    assert asked[0][1]["skill_name"] == "himalaya"


def test_loading_himalaya_with_a_password_does_not_prompt_and_forwards_it(tmp_path, monkeypatch):
    from tools.env_passthrough import is_env_passthrough
    monkeypatch.setenv("HIMALAYA_PASSWORD", CANARY)
    result = _load_real_skill(tmp_path, monkeypatch, lambda *a, **k: pytest.fail("prompted"))
    assert result["success"] is True
    assert is_env_passthrough("HIMALAYA_PASSWORD")
    assert CANARY not in json.dumps(result)


def test_v2_secret_command_failure_is_a_missing_password_need():
    need = auth_required.detect("terminal", LIST, terminal_result(V2_SECRET_COMMAND_FAILED, 1))
    assert need == auth_required.AuthNeed("email:himalaya", "missing", "api_key")


def test_v2_server_rejection_stays_an_expired_password_need():
    need = auth_required.detect("terminal", LIST, terminal_result(V2_SERVER_REJECTED, 1))
    assert need == auth_required.AuthNeed("email:himalaya", "expired", "api_key")


def test_v2_smtp_rejection_is_an_expired_password_need():
    need = auth_required.detect("terminal", {"command": "himalaya message send"}, terminal_result(V2_SMTP_REJECTED, 1))
    assert need == auth_required.AuthNeed("email:himalaya", "expired", "api_key")


@pytest.mark.parametrize("command,output,code", [
    ("himalaya mailbox list", V2_SECRET_COMMAND_FAILED, 0),
    ("echo himalaya", V2_SECRET_COMMAND_FAILED, 1),
    ("himalaya mailbox list", "Error: Spawn secret command error" + V2_BACKTRACE, 1),
    ("himalaya mailbox list", "mail body: Secret command error was in the subject", 1),
])
def test_unrelated_secret_command_text_never_triggers_the_popup(command, output, code):
    assert auth_required.detect("terminal", {"command": command}, terminal_result(output, code)) is None


def _prompting(monkeypatch, outcome):
    from gateway import auth_prompts
    prompts = []
    monkeypatch.setattr(auth_prompts, "call_from_thread",
                        lambda home, need, bot: prompts.append(need) or outcome(auth_prompts))
    return prompts


def test_missing_password_prompts_once_retries_once_then_plain_auth_failed(monkeypatch):
    prompts = _prompting(monkeypatch, lambda m: m.Resolution.SIGNED_IN)
    failing = terminal_result(V2_SECRET_COMMAND_FAILED, 1)
    calls = []
    out = auth_required.resolve("terminal", LIST, failing, lambda: calls.append(1) or failing)
    assert [p.reason for p in prompts] == ["missing"] and len(calls) == 1
    assert json.loads(out)["error_type"] == "auth_failed"


def test_missing_password_then_good_password_returns_the_retried_result(monkeypatch):
    _prompting(monkeypatch, lambda m: m.Resolution.SIGNED_IN)
    ok = terminal_result("NAME  ID\nINBOX 1", 0)
    assert auth_required.resolve("terminal", LIST, terminal_result(V2_SECRET_COMMAND_FAILED, 1), lambda: ok) == ok


@pytest.mark.parametrize("outcome,error_type", [("DECLINED", "auth_declined"), ("TIMED_OUT", "auth_timeout")])
def test_missing_password_decline_and_timeout_are_not_retried(monkeypatch, outcome, error_type):
    _prompting(monkeypatch, lambda m: getattr(m.Resolution, outcome))
    out = auth_required.resolve("terminal", LIST, terminal_result(V2_SECRET_COMMAND_FAILED, 1),
                                lambda: pytest.fail("retried"))
    assert json.loads(out)["error_type"] == error_type


def test_canary_password_never_reaches_a_failure_result_or_log(monkeypatch, caplog):
    _prompting(monkeypatch, lambda m: m.Resolution.SIGNED_IN)
    monkeypatch.setenv("HIMALAYA_PASSWORD", CANARY)
    failing = terminal_result(V2_SERVER_REJECTED, 1)
    with caplog.at_level("DEBUG"):
        out = auth_required.resolve("terminal", LIST, terminal_result(V2_SECRET_COMMAND_FAILED, 1), lambda: failing)
    assert CANARY not in out and CANARY not in caplog.text
