from __future__ import annotations

import json
import os
import sys
from contextlib import contextmanager
from pathlib import Path

import hermes_yaml as yaml
import pytest

import model_tools
from agent.secret_scope import current_secret_scope
from hermes_cli.config import load_config
from hermes_cli.tools_config import _get_platform_tools
from tools import mcp_action_gate, mcp_tool
from tools import mcp_tool_handlers as handlers
from tools import mcp_tool_registration as registration
from tools.mcp_tool_common import mcp_server_enabled
from tools.mcp_tool_config import connector_configs
from tools.registry import registry

URL = "https://mcp.upwork.com/mcp"
TOOL = "mcp_upwork_search_jobs"
ROOT_ENTRY = {"enabled": True, "auth": "oauth",
              "action_policy": {"read_tools": ["search_jobs"], "refused_tools": ["fund_escrow"]}}
GITHUB_KEY = "MCP_GITHUB_API_KEY"
DISCORD_KEY = "DISCORD_BOT_TOKEN"
GITHUB = {"url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}
DISCORD = {"command": sys.executable, "args": ["-m", "discord_server"], "env": {"TOKEN": f"${{{DISCORD_KEY}}}"}}


def write_servers(home: Path, servers: dict) -> None:
    (home / "config.yaml").write_text(yaml.safe_dump({"model": {}, "mcp_servers": servers}))


def write_env(home: Path, **values: str) -> None:
    (home / ".env").write_text("".join(f"{key}={value}\n" for key, value in values.items()))


@pytest.fixture
def world(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    bot = root / "profiles" / "bot"
    bot.mkdir(parents=True)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    (bot / "config.yaml").write_text("model: {}\n")
    write_servers(root, {"upwork": ROOT_ENTRY, "github": {"enabled": True}, "discord": {"enabled": True}})
    monkeypatch.delenv(GITHUB_KEY, raising=False)
    monkeypatch.delenv(DISCORD_KEY, raising=False)
    catalog = root / "shared" / "catalog"
    catalog.mkdir(parents=True)
    (catalog / ".migrated").write_text("")
    (catalog / "mcp_servers.yaml").write_text(yaml.safe_dump({"upwork": {"url": URL}, "github": GITHUB, "discord": DISCORD}))
    return root, bot


@contextmanager
def acting_as(home: Path):
    previous = os.environ["HERMES_HOME"]
    os.environ["HERMES_HOME"] = str(home)
    try:
        yield
    finally:
        os.environ["HERMES_HOME"] = previous


def test_a_money_step_is_refused_when_a_bot_calls_the_shared_server(world, monkeypatch):
    _root, bot = world
    monkeypatch.setattr(mcp_tool, "_server_action_policies", {})
    monkeypatch.setattr(mcp_tool, "_server_trust_levels", {})
    monkeypatch.setattr(mcp_tool, "_server_cost_policies", {})
    monkeypatch.setattr(mcp_tool, "_tool_read_only_hints", {})
    with acting_as(bot):
        (_connection, config), = connector_configs("upwork", interpolate=False).items()
        registration._record_tool_trust_metadata("upwork", config, [])
        refused = json.loads(handlers._trust_gate_check("upwork", "fund_escrow", args={"contract_id": "1"}))
        read = handlers._trust_gate_check("upwork", "search_jobs", args={"q": "python"})
    assert refused["code"] == mcp_action_gate.ACTION_REFUSED
    assert read is None


def test_the_shared_servers_tools_are_behind_tool_search_for_a_bot(world, monkeypatch):
    _root, bot = world
    registry.register(
        name=TOOL, toolset="mcp-upwork", handler=lambda args, **kw: json.dumps({"ok": True}),
        schema={"name": TOOL, "description": "Search Upwork jobs.", "parameters": {"type": "object", "properties": {}}})
    registry.register_toolset_alias("upwork", "mcp-upwork")
    model_tools._clear_tool_defs_cache()
    try:
        with acting_as(bot):
            toolsets = sorted(_get_platform_tools(load_config(), "cli"))
        assert "upwork" in toolsets
        eager = [d["function"]["name"] for d in model_tools.get_tool_definitions(
            enabled_toolsets=toolsets, quiet_mode=True)]
        full = [d["function"]["name"] for d in model_tools.get_tool_definitions(
            enabled_toolsets=toolsets, quiet_mode=True, skip_tool_search_assembly=True)]
        assert TOOL in full and TOOL not in eager
        assert "tool_search" in eager
        found, _redispatch = model_tools._dispatch_bridge_tool("tool_search", {"queries": ["search jobs"], "limit": 50}, toolsets, None)
        assert TOOL in json.loads(found)["results"][0]["matches"]
    finally:
        registry.deregister(TOOL)
        model_tools._clear_tool_defs_cache()


def rendered(name: str) -> dict:
    (config,) = connector_configs(name).values()
    return config


def test_a_bot_renders_a_shared_key_servers_header_with_the_roots_key(world):
    root, bot = world
    write_env(root, **{GITHUB_KEY: "root-key"})
    with acting_as(bot):
        assert rendered("github")["headers"]["Authorization"] == "Bearer root-key"
        assert GITHUB_KEY not in os.environ
        assert GITHUB_KEY not in (current_secret_scope() or {})


def test_a_bots_own_value_for_the_same_variable_never_replaces_the_roots(world):
    root, bot = world
    write_env(root, **{GITHUB_KEY: "root-key"})
    write_env(bot, **{GITHUB_KEY: "bot-key"})
    with acting_as(bot):
        assert rendered("github")["headers"]["Authorization"] == "Bearer root-key"


def test_a_shared_key_server_the_root_has_no_key_for_stays_unresolved_for_a_bot_that_has_one(world):
    from tools.mcp_tool_config import _require_rendered_remote

    _root, bot = world
    write_env(bot, **{GITHUB_KEY: "bot-key"})
    with acting_as(bot):
        config = rendered("github")
        assert "bot-key" not in config["headers"]["Authorization"]
        with pytest.raises(ValueError) as refused:
            _require_rendered_remote("github", config)
    assert "Connect apps" in str(refused.value) and "this profile's" not in str(refused.value)
    assert "bot-key" not in str(refused.value)


def test_a_key_server_the_root_owns_but_switched_off_stays_off_for_a_bot_that_has_its_own_key_and_entry(world):
    root, bot = world
    write_servers(root, {"upwork": ROOT_ENTRY, "github": {"enabled": False}})
    write_servers(bot, {"github": {"enabled": True}})
    write_env(root, **{GITHUB_KEY: "root-key"})
    write_env(bot, **{GITHUB_KEY: "bot-key"})
    with acting_as(bot):
        assert not mcp_server_enabled(rendered("github"))


def test_a_key_server_only_the_bot_has_renders_with_the_bots_own_key(world):
    root, bot = world
    write_servers(bot, {"mine": {"enabled": True, "url": "https://mine.example/mcp",
                                 "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    write_env(root, **{GITHUB_KEY: "root-key"})
    write_env(bot, **{GITHUB_KEY: "bot-key"})
    with acting_as(bot):
        assert rendered("mine")["headers"]["Authorization"] == "Bearer bot-key"


def test_a_shared_stdio_servers_env_secret_resolves_from_the_root_for_a_bot(world):
    root, bot = world
    write_env(root, **{DISCORD_KEY: "root-token"})
    write_env(bot, **{DISCORD_KEY: "bot-token"})
    with acting_as(bot):
        assert rendered("discord")["env"] == {"TOKEN": "root-token"}


def test_the_connect_time_render_of_a_shared_server_also_uses_the_roots_key(world):
    from tools.mcp_tool_config import _interpolate_env_vars

    root, bot = world
    write_env(root, **{GITHUB_KEY: "root-key"})
    write_env(bot, **{GITHUB_KEY: "bot-key"})
    with acting_as(bot):
        raw = connector_configs("github", interpolate=False)["github"]
        assert _interpolate_env_vars(raw, "github")["headers"]["Authorization"] == "Bearer root-key"
