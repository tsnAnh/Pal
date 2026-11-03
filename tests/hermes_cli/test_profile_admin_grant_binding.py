import json
import os
import sys
import time
from pathlib import Path

import pytest

from hermes_cli import profile_admin_guard as guard
from hermes_cli.profile_admin_guard import ProfileAdminDenied, require_profile_admin_grant
from tools import approval

REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(autouse=True)
def agent_context(monkeypatch):
    monkeypatch.setenv(guard.AGENT_TOOL_MARKER_ENV, "1")
    monkeypatch.delenv(guard.GRANT_ENV, raising=False)
    guard._spent_tokens.clear()
    yield
    guard._spent_tokens.clear()


@pytest.fixture
def owner_approves(monkeypatch):
    def gate(command, description, approval_callback=None):
        return {"approved": True, "user_approved": True, "human_required": True, "description": description}

    monkeypatch.setattr(approval, "_human_required_gate", gate)


def approved_grant(command, owner_approves):
    verdict = approval.check_all_command_guards(command, "local")
    assert verdict["approved"], verdict
    return verdict["profile_admin_grant"]


def approved_code_grant(code, owner_approves):
    verdict = approval.check_execute_code_guard(code, "local")
    assert verdict["approved"], verdict
    return verdict["profile_admin_grant"]


def spend(token, action, name=""):
    os.environ[guard.GRANT_ENV] = token
    try:
        require_profile_admin_grant(action, name)
    finally:
        os.environ.pop(guard.GRANT_ENV, None)


def assert_refused(token, action, name=""):
    with pytest.raises(ProfileAdminDenied):
        spend(token, action, name)


def test_create_grant_cannot_delete(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    assert_refused(token, "delete", "other")


def test_create_grant_cannot_delete_same_name(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    assert_refused(token, "delete", "shop")


def test_create_grant_for_one_name_cannot_create_another(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    assert_refused(token, "create", "other")


def test_refused_attempt_spends_the_grant(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    assert_refused(token, "create", "other")
    assert_refused(token, "create", "shop")


def test_matching_create_is_allowed_once_then_replay_refused(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    spend(token, "create", "shop")
    assert_refused(token, "create", "shop")
    assert_refused(token, "create", "other")


def test_name_comparison_uses_the_existing_normalization(owner_approves):
    token = approved_grant("hermes profile create Shop", owner_approves)
    spend(token, "create", "  shop ")


def test_bot_create_grant_allows_create_only(owner_approves):
    token = approved_grant("hermes bot create shop --display-name 'Shop Bot'", owner_approves)
    spend(token, "create", "shop")
    other = approved_grant("hermes bot create shop", owner_approves)
    assert_refused(other, "delete", "shop")


def test_create_flags_with_values_do_not_become_the_name(owner_approves):
    token = approved_grant("hermes profile create --clone-from base --description hi shop", owner_approves)
    assert_refused(token, "create", "base")


def test_create_rollback_delete_of_same_subject_still_works(owner_approves):
    token = approved_grant("hermes profile create shop", owner_approves)
    spend(token, "create", "shop")
    spend(token, "delete", "shop")
    assert_refused(token, "delete", "other")


def test_delete_grant_matches_name_only(owner_approves):
    token = approved_grant("hermes profile delete shop -y", owner_approves)
    assert_refused(token, "delete", "other")
    token = approved_grant("hermes profile delete shop -y", owner_approves)
    assert_refused(token, "create", "shop")
    token = approved_grant("hermes profile delete shop -y", owner_approves)
    spend(token, "delete", "shop")


def test_dynamic_name_binds_the_action_only(owner_approves):
    token = approved_grant('NAME=shop; hermes profile create "$NAME"', owner_approves)
    spend(token, "create", "anything")
    token = approved_grant('NAME=shop; hermes profile create "$NAME"', owner_approves)
    assert_refused(token, "delete", "shop")


def test_import_and_install_bind_the_override_name(owner_approves):
    token = approved_grant("hermes profile import backup.tar.gz --name shop", owner_approves)
    assert_refused(token, "import", "other")
    token = approved_grant("hermes profile import backup.tar.gz --name shop", owner_approves)
    spend(token, "import", "shop")
    token = approved_grant("hermes profile install github.com/acme/dist --name shop", owner_approves)
    assert_refused(token, "create", "shop")
    token = approved_grant("hermes profile install github.com/acme/dist", owner_approves)
    spend(token, "install", "inferred-from-manifest")


def test_shared_mcp_grants_work_and_do_not_cross_over(owner_approves):
    token = approved_grant("hermes mcp add srv --url https://x.example --replace-shared", owner_approves)
    spend(token, "mcp_replace_shared", "srv")

    token = approved_grant("hermes mcp add srv --url https://x.example --replace-shared", owner_approves)
    assert_refused(token, "mcp_replace_shared", "other")
    token = approved_grant("hermes mcp add srv --url https://x.example --replace-shared", owner_approves)
    assert_refused(token, "mcp_remove_everywhere", "srv")
    token = approved_grant("hermes mcp add srv --url https://x.example --replace-shared", owner_approves)
    assert_refused(token, "delete", "srv")

    token = approved_grant("hermes mcp remove srv --everywhere", owner_approves)
    spend(token, "mcp_remove_everywhere", "srv")
    token = approved_grant("hermes mcp rm srv --everywhere", owner_approves)
    assert_refused(token, "mcp_replace_shared", "srv")


def test_catalog_grant_works_and_does_not_cross_over(owner_approves):
    token = approved_grant("hermes catalog migrate", owner_approves)
    spend(token, "catalog_migrate")
    token = approved_grant("hermes catalog migrate", owner_approves)
    assert_refused(token, "delete", "shop")
    token = approved_grant("hermes profile create shop", owner_approves)
    assert_refused(token, "catalog_migrate")


def test_python_api_code_grant_binds_the_action(owner_approves):
    code = "from hermes_cli.profiles import create_profile\ncreate_profile('shop')\n"
    token = approved_code_grant(code, owner_approves)
    assert_refused(token, "delete", "shop")
    token = approved_code_grant(code, owner_approves)
    spend(token, "create", "shop")


def write_grant(payload):
    token = "ab" * 32
    directory = guard._grants_dir()
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(directory / token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    return token


def test_grant_without_bindings_authorizes_nothing():
    token = write_grant({
        "command_sha256": guard._command_digest("hermes profile create shop"),
        "description": "create a bot or profile",
        "root": guard._root_key(),
        "expires_at": time.time() + 60,
    })
    assert_refused(token, "create", "shop")


@pytest.mark.parametrize("bindings", [None, [], "create", [{"name": "shop"}], [{"action": 3}], [{"action": "create"}], [["create", "shop"]]])
def test_malformed_bindings_authorize_nothing(bindings):
    token = write_grant({
        "command_sha256": guard._command_digest("hermes profile create shop"),
        "description": "create a bot or profile",
        "root": guard._root_key(),
        "expires_at": time.time() + 60,
        "bindings": bindings,
    })
    assert_refused(token, "create", "shop")


SHADOW_SCRIPT = """\
import sys
sys.path.insert(0, {repo!r})
from hermes_cli.profiles import delete_profile
delete_profile("x")
"""


def test_shell_function_shadowing_hermes_cannot_spend_the_grant(tmp_path, monkeypatch, owner_approves):
    from tools import terminal_tool

    shell_home = tmp_path / "shell-home"
    shell_home.mkdir()
    hermes_home = tmp_path / ".hermes"
    victim = hermes_home / "profiles" / "x"
    victim.mkdir(parents=True)
    (victim / "config.yaml").write_text("{}\n")
    script = tmp_path / "shadow.py"
    script.write_text(SHADOW_SCRIPT.format(repo=str(REPO_ROOT)))
    (shell_home / ".bash_profile").write_text(f"hermes() {{ {sys.executable} {script}; }}\n")
    monkeypatch.setenv("HOME", str(shell_home))
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))
    monkeypatch.delenv(guard.AGENT_TOOL_MARKER_ENV, raising=False)
    monkeypatch.setattr(Path, "home", lambda: shell_home)

    try:
        result = json.loads(terminal_tool.terminal_tool(command="hermes profile create shop"))
    finally:
        terminal_tool.cleanup_all_environments()

    assert result["exit_code"] != 0, result
    assert "needs your approval" in result["output"], result
    assert victim.is_dir()


def test_create_grant_for_an_existing_profile_cannot_delete_it(owner_approves):
    from hermes_cli.profiles import get_profile_dir
    get_profile_dir("shop").mkdir(parents=True)
    token = approved_grant("hermes profile create shop", owner_approves)
    spend(token, "create", "shop")
    assert_refused(token, "delete", "shop")


@pytest.mark.parametrize("command, action, name, wrong", [
    ("hermes profile create -p base shop", "create", "shop", "base"),
    ("hermes profile delete -p base shop -y", "delete", "shop", "base"),
    ("hermes profile delete --profile base shop -y", "delete", "shop", "base"),
    ("hermes bot create -p base shop", "create", "shop", "base"),
    ("hermes mcp remove -p base srv --everywhere", "mcp_remove_everywhere", "srv", "base"),
    ("hermes mcp add -p base srv --url https://x --replace-shared", "mcp_replace_shared", "srv", "base"),
    ("hermes profile create --clone shop", "create", "shop", "other"),
    ("hermes profile create --clone --description victim shop", "create", "shop", "victim"),
    ("hermes profile create --clone --clone-from base shop", "create", "shop", "base"),
])
def test_grant_binds_the_real_name_not_a_flag_or_its_value(command, action, name, wrong, owner_approves):
    spend(approved_grant(command, owner_approves), action, name)
    assert_refused(approved_grant(command, owner_approves), action, wrong)
