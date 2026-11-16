import json

import pytest

from gateway import auth_prompts
from tools import auth_required

CANARY = "ya29.CANARYTOKEN0123456789-client-secret"
SKILL = "/root/.hermes/skills/productivity/google-workspace/scripts"
API = f"python {SKILL}/google_api.py gmail search is:unread"
SETUP = f"python {SKILL}/setup.py --check"
NEED = auth_required.GOOGLE_WORKSPACE_SERVICE


def terminal_result(output, code=1):
    return json.dumps({"output": output, "exit_code": code})


def detect(command, output, code=1):
    return auth_required.detect("terminal", {"command": command}, terminal_result(output, code))


@pytest.mark.parametrize("command,output,reason", [
    (API, "Not authenticated. Run the setup script first:\n  python /x/setup.py\n", "missing"),
    (SETUP, "NOT_AUTHENTICATED: No token at /x/google_token.json", "missing"),
    (SETUP, "TOKEN_REVOKED: invalid_grant: Token has been expired or revoked.\n  Re-run setup to re-authenticate.", "revoked"),
    (SETUP, "TOKEN_CORRUPT: Expecting value", "expired"),
    (SETUP, "REFRESH_FAILED: network down", "expired"),
    (SETUP, "TOKEN_INVALID: Re-run setup.", "expired"),
    ('GAPI="python /h/skills/productivity/google-workspace/scripts/google_api.py"\n$GAPI gmail labels',
     "Not authenticated. Run the setup script first:", "missing"),
    (f"cd /tmp && HERMES_HOME=/h {API}", "Not authenticated. Run the setup script first:", "missing"),
])
def test_skill_failures_become_one_google_need(command, output, reason):
    assert detect(command, output) == auth_required.AuthNeed(NEED, reason, "oauth_paste")


@pytest.mark.parametrize("command,output,code", [
    (API, "Not authenticated. Run the setup script first:", 0),
    (SETUP, "OAUTH_CLIENT_DISABLED: invalid_client\n  The OAuth client or Google account has been disabled.", 1),
    (SETUP, "LIVE_CHECK_FAILED: timeout", 1),
    ("ls", "Not authenticated. Run the setup script first:", 1),
    ("grep -r 'Not authenticated' /h/skills/productivity/google-workspace/scripts/google_api.py",
     "Not authenticated. Run the setup script first:", 1),
    ("cat /h/skills/productivity/google-workspace/scripts/setup.py", "NOT_AUTHENTICATED: x", 1),
    ("echo NOT_AUTHENTICATED", "NOT_AUTHENTICATED: x", 1),
    ("python /tmp/setup.py --check", "NOT_AUTHENTICATED: x", 1),
    ('GAPI="python /h/skills/productivity/google-workspace/scripts/google_api.py"', "Not authenticated.", 1),
    ("$GAPI gmail labels", "Not authenticated. Run the setup script first:", 1),
    (f"echo {SKILL}/google_api.py", "Not authenticated. Run the setup script first:", 1),
])
def test_other_outputs_never_trigger_the_popup(command, output, code):
    assert detect(command, output, code) is None


def test_failed_sign_in_retries_once_and_does_not_loop(monkeypatch):
    prompts = []
    monkeypatch.setattr(auth_prompts, "call_from_thread",
                        lambda home, need, bot: prompts.append(need) or auth_prompts.Resolution.SIGNED_IN)
    failing = terminal_result("Not authenticated. Run the setup script first:")
    calls = []
    out = auth_required.resolve("terminal", {"command": API}, failing, lambda: calls.append(1) or failing)
    assert len(prompts) == 1 and len(calls) == 1
    assert json.loads(out)["error_type"] == "auth_failed"


def test_canary_in_skill_output_stays_out_of_the_need_and_failure(monkeypatch, caplog):
    output = f"TOKEN_REVOKED: invalid_grant {CANARY}"
    need = detect(SETUP, output)
    assert need is not None and CANARY not in repr(need)
    monkeypatch.setattr(auth_prompts, "call_from_thread", lambda *a: auth_prompts.Resolution.DECLINED)
    out = auth_required.resolve("terminal", {"command": SETUP}, terminal_result(output), lambda: None)
    assert CANARY not in out and CANARY not in caplog.text
    assert auth_required.service_display_name(NEED) == "Google Workspace"
