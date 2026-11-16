"""Every reader of a config file masks credential keys with the fixed placeholder (no prefix, no length)."""

import json
import subprocess

import pytest

from agent.redact import redact_terminal_output
from agent.redact_config import CONFIG_SECRET_PLACEHOLDER

HASH = "fake-hash-do-not-use"
SECRET = "fake-webapp-secret-do-not-use"
CONFIG = (
    "model: some-model\n"
    "webapp:\n"
    "  enabled: true\n"
    f"  password_hash: {HASH}\n"
    f"  secret: {SECRET}\n"
    "dashboard:\n"
    "  basic_auth:\n"
    "    username: bob\n"
    f"    password_hash: {HASH}\n"
    f"    secret: \"{SECRET}\"\n"
    "    session_ttl_seconds: 5\n"
    "  theme: midnight\n")


def _assert_clean(out):
    for fragment in (HASH, SECRET, "fake-h", "fake-w", "-use"):
        assert fragment not in out, out
    assert CONFIG_SECRET_PLACEHOLDER in out


@pytest.fixture
def home(tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    home.mkdir()
    (home / "config.yaml").write_text(CONFIG, encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))
    import hermes_cli.config as cfg
    cfg._LOAD_CONFIG_CACHE.clear()
    cfg._RAW_CONFIG_CACHE.clear()
    return home


@pytest.mark.parametrize("command", [
    "cat config.yaml",
    "cd ~/.hermes && cat config.yaml",
    "head -50 config.yaml",
    "sed -n 1,40p config.yaml",
    "grep -n -i -B1 -A3 webapp config.yaml",
    "grep -rn secret ~/.hermes",
    "cat ~/.hermes/config.yaml",
    "python3 -c 'print(open(\"config.yaml\").read())'",
])
def test_terminal_output_of_any_config_read_masks_credentials(command):
    output = CONFIG
    if command.startswith("grep"):
        output = "\n".join(f"/root/.hermes/config.yaml:{n}:{line}" if "-rn" in command else f"{n}:{line}"
                           for n, line in enumerate(CONFIG.splitlines(), 1) if "hash" in line or "secret" in line)
    _assert_clean(redact_terminal_output(output, command))


def test_terminal_output_keeps_non_secret_keys_and_structure():
    out = redact_terminal_output(CONFIG, "cat config.yaml")
    for kept in ("model: some-model", "enabled: true", "username: bob", "session_ttl_seconds: 5", "theme: midnight"):
        assert kept in out
    assert f"password_hash: {CONFIG_SECRET_PLACEHOLDER}" in out
    assert f'secret: "{CONFIG_SECRET_PLACEHOLDER}"' in out


def test_nested_section_and_list_items_are_masked():
    text = f"mcp_servers:\n  - name: a\n    client_secret: {SECRET}\n  - name: b\n    admin_password_hash: {HASH}\n"
    out = redact_terminal_output(text, "cat settings.yaml")
    assert SECRET not in out and HASH not in out and "name: a" in out and "name: b" in out


def test_env_references_and_empty_values_are_left_alone():
    text = "password_hash: \"\"\nsecret: ${WEBAPP_SECRET}\nsecret: <your secret>\n"
    assert redact_terminal_output(text, "cat config.yaml") == text


@pytest.mark.parametrize("where", ["hermes-home", "project"])
def test_read_file_masks_credentials(home, tmp_path, where):
    from tools.file_tools import read_file_tool

    path = home / "config.yaml"
    if where == "project":
        path = tmp_path / "project" / "config.yaml"
        path.parent.mkdir()
        path.write_text(CONFIG, encoding="utf-8")
    out = read_file_tool(str(path))
    assert SECRET not in out and HASH not in out and "fake-h" not in out
    if where == "project":
        assert "model: some-model" in json.loads(out)["content"]


def test_search_files_masks_credentials(home):
    from tools.file_tools import search_tool

    out = search_tool(pattern="password_hash|secret", path=str(home))
    assert SECRET not in out and HASH not in out and "fake-h" not in out


@pytest.mark.parametrize("key", ["webapp", "dashboard", "dashboard.basic_auth", "webapp.secret",
                                 "dashboard.basic_auth.password_hash"])
def test_config_get_masks_credentials(home, capsys, key):
    from hermes_cli.config import get_config_value

    get_config_value(key)
    out = capsys.readouterr().out
    assert SECRET not in out and HASH not in out and "fake-h" not in out and "fake-w" not in out
    assert CONFIG_SECRET_PLACEHOLDER in out


def test_config_get_non_secret_key_reads_normally(home, capsys):
    from hermes_cli.config import get_config_value

    get_config_value("dashboard.basic_auth.username")
    assert capsys.readouterr().out.strip() == "bob"


def test_config_show_prints_no_credentials(home, capsys):
    from hermes_cli.config_show import show_config

    show_config()
    out = capsys.readouterr().out
    assert SECRET not in out and HASH not in out and "fake-h" not in out
