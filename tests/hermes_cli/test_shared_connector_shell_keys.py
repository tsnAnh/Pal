from __future__ import annotations

from types import SimpleNamespace

import pytest

from hermes_cli import mcp_config
from hermes_cli.config import load_config, set_config_value
from hermes_cli.mcp_config import mcp_command
from hermes_cli.profile_admin_guard import AGENT_TOOL_MARKER_ENV
from hermes_cli.shared_catalog import effective_mcp_servers
from tests.hermes_cli.test_shared_connectors import GITHUB_KEY, GITHUB_URL, World, cli_add, make_world
from tools.mcp_tool_config import _interpolate_env_vars, _require_rendered_remote

SHELL_VALUE = "ghp_only_in_the_shell"
OTHER_KEY = "GITHUB_TOKEN"


def header_entry(*keys: str) -> dict:
    return {
        "url": GITHUB_URL, "enabled": True,
        "headers": {f"X-Key-{i}": f"Bearer ${{{key}}}" for i, key in enumerate(keys)},
    }


@pytest.fixture
def world(tmp_path, monkeypatch) -> World:
    return make_world(tmp_path, monkeypatch)


@pytest.fixture(autouse=True)
def a_shell_without_the_keys(monkeypatch):
    for key in (GITHUB_KEY, OTHER_KEY, "MINE_KEY"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(mcp_config, "_probe_single_server", lambda *_a, **_k: [("search_repos", "Search")])


def run_test_command(name: str) -> None:
    mcp_command(SimpleNamespace(mcp_action="test", name=name))


def test_a_shell_only_key_is_saved_to_the_roots_env_when_the_owner_adds_a_shared_server(world, monkeypatch, capsys):
    world.write_servers(world.root, {})
    key = mcp_config._env_key_for_server("ghsrv")
    monkeypatch.setenv(key, SHELL_VALUE)
    monkeypatch.setattr(mcp_config, "get_env_value", lambda var, *_a, **_k: "set" if var == key else None)
    with world.acting_as(world.bot):
        cli_add(monkeypatch, "ghsrv", GITHUB_URL, "")
    out = capsys.readouterr().out
    assert world.env(world.root) == {key: SHELL_VALUE}
    assert world.env(world.bot) == {}
    assert f"Saved {key} from your shell to the shared setup so every bot can use it" in out
    assert SHELL_VALUE not in out
    monkeypatch.delenv(key)
    with world.acting_as(world.other):
        servers = effective_mcp_servers(load_config().get("mcp_servers"))
        rendered = _interpolate_env_vars(servers["ghsrv"], "ghsrv")
    assert rendered["headers"]["Authorization"] == f"Bearer {SHELL_VALUE}"


def test_a_key_the_root_already_has_is_never_overwritten_and_only_the_missing_one_is_imported(world, monkeypatch, capsys):
    world.write_servers(world.root, {"github": header_entry(GITHUB_KEY, OTHER_KEY)})
    world.put_env(world.root, **{GITHUB_KEY: "root-value"})
    monkeypatch.setenv(GITHUB_KEY, SHELL_VALUE)
    monkeypatch.setenv(OTHER_KEY, "ghp_second_shell_value")
    with world.acting_as(world.bot):
        run_test_command("github")
    out = capsys.readouterr().out
    assert world.env(world.root) == {GITHUB_KEY: "root-value", OTHER_KEY: "ghp_second_shell_value"}
    assert f"Saved {OTHER_KEY} from your shell" in out
    assert f"Saved {GITHUB_KEY} from your shell" not in out
    assert SHELL_VALUE not in out and "ghp_second_shell_value" not in out


def test_an_agent_never_imports_shell_keys(world, monkeypatch, capsys):
    world.write_servers(world.root, {})
    monkeypatch.setenv(AGENT_TOOL_MARKER_ENV, "1")
    monkeypatch.setenv(GITHUB_KEY, SHELL_VALUE)
    with world.acting_as(world.bot):
        cli_add(monkeypatch, "github", GITHUB_URL, "")
    assert world.env(world.root) == {} and world.servers(world.root) == {}
    assert "from your shell" not in capsys.readouterr().out


def test_an_agent_testing_a_shared_server_imports_nothing(world, monkeypatch, capsys):
    world.write_servers(world.root, {"github": header_entry(GITHUB_KEY)})
    monkeypatch.setenv(AGENT_TOOL_MARKER_ENV, "1")
    monkeypatch.setenv(GITHUB_KEY, SHELL_VALUE)
    with world.acting_as(world.bot):
        run_test_command("github")
    assert world.env(world.root) == {}
    assert "from your shell" not in capsys.readouterr().out


def test_a_server_only_the_bot_has_never_imports_into_the_root(world, monkeypatch, capsys):
    world.write_servers(world.bot, {"mine": header_entry("MINE_KEY")})
    monkeypatch.setenv("MINE_KEY", SHELL_VALUE)
    with world.acting_as(world.bot):
        run_test_command("mine")
    assert world.env(world.root) == {} and world.env(world.bot) == {}
    assert "from your shell" not in capsys.readouterr().out


def test_a_key_set_nowhere_prints_the_exact_fix_for_a_shared_server_run_from_a_bot(world, capsys):
    world.write_servers(world.root, {"github": header_entry(GITHUB_KEY)})
    with world.acting_as(world.bot):
        run_test_command("github")
    out = capsys.readouterr().out
    assert f'hermes -p default config set {GITHUB_KEY} "${GITHUB_KEY}"' in out


def test_a_key_set_nowhere_prints_the_plain_command_when_the_owner_runs_from_the_root(world, capsys):
    world.write_servers(world.root, {"github": header_entry(GITHUB_KEY)})
    run_test_command("github")
    out = capsys.readouterr().out
    assert f'hermes config set {GITHUB_KEY} "${GITHUB_KEY}"' in out
    assert "-p " not in out


def test_a_key_set_nowhere_prints_the_bots_own_fix_for_a_server_only_the_bot_has(world, capsys):
    world.write_servers(world.bot, {"mine": header_entry("MINE_KEY")})
    with world.acting_as(world.bot):
        run_test_command("mine")
    assert 'hermes -p bot config set MINE_KEY "$MINE_KEY"' in capsys.readouterr().out


def test_a_key_set_nowhere_is_named_when_adding_a_server_that_cannot_connect(world, monkeypatch, capsys):
    world.write_servers(world.root, {})

    def refuse(*_a, **_k):
        raise ConnectionError("refused")

    monkeypatch.setattr(mcp_config, "_confirm", lambda question, **_k: "authentication" in question)
    monkeypatch.setattr(mcp_config, "_probe_single_server", refuse)
    monkeypatch.setattr("hermes_cli.cli_output.prompt", lambda *_a, **_k: "")
    key = mcp_config._env_key_for_server("ghost")
    monkeypatch.setattr(mcp_config, "get_env_value", lambda var, *_a, **_k: "set" if var == key else None)
    with world.acting_as(world.bot):
        mcp_command(SimpleNamespace(
            mcp_action="add", name="ghost", url=GITHUB_URL, mcp_command=None, args=[], auth="header",
            preset=None, env=None, replace_shared=False, connect_timeout=None))
    assert f'hermes -p default config set {key} "${key}"' in capsys.readouterr().out


@pytest.mark.parametrize("key", [GITHUB_KEY, OTHER_KEY, "SLACK_BOT"])
def test_the_printed_config_set_command_stores_the_key_in_the_roots_env(world, key):
    set_config_value(key, "stored-value")
    assert world.env(world.root) == {key: "stored-value"}


def test_the_error_an_app_can_surface_for_a_missing_shared_key_stays_in_product_language(world):
    world.write_servers(world.root, {"github": header_entry(GITHUB_KEY)})
    for home in (world.bot, world.root):
        with world.acting_as(home), pytest.raises(ValueError) as refused:
            _require_rendered_remote("github", _interpolate_env_vars(header_entry(GITHUB_KEY), "github"))
        text = str(refused.value)
        assert GITHUB_KEY in text
        assert "$" not in text and "config set" not in text and ".env" not in text
