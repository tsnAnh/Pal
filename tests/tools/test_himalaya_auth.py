import asyncio
import json

import pytest

from gateway import auth_flows
from tools import auth_required
from tools.skills_tool_setup import _get_required_environment_variables

CANARY = "canary-app-password-7391"


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
