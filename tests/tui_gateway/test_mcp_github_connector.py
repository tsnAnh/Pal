from __future__ import annotations

import logging
from types import SimpleNamespace
from unittest.mock import patch

import pytest

import hermes_yaml as yaml
from hermes_cli import mcp_catalog
from tui_gateway import server

CANARY = "github_pat_CANARY0123456789abcdef"

WRITE_TOOLS = (
    "create_issue", "issue_write", "add_issue_comment", "update_issue_comment", "sub_issue_write",
    "merge_pull_request", "create_pull_request", "update_pull_request", "update_pull_request_branch",
    "pull_request_review_write", "add_comment_to_pending_review", "add_reply_to_pull_request_comment",
    "delete_file", "create_or_update_file", "push_files", "fork_repository", "create_branch",
    "create_repository", "delete_repository", "actions_run_trigger", "label_write",
    "create_pull_request_with_copilot", "assign_copilot_to_issue", "request_copilot_review",
)


@pytest.fixture
def github_entry():
    entry = mcp_catalog.get_entry("github")
    assert entry is not None
    return entry


@pytest.fixture
def hermes_root(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def _call(method, params=None):
    return server._methods[method](1, params or {})


def _result(resp):
    assert "error" not in resp, resp.get("error")
    return resp["result"]


def _fake_tool(name):
    return SimpleNamespace(name=name, description=f"{name} tool", inputSchema={"type": "object", "properties": {}})


def _register(tool_names, config):
    from tools.mcp_tool import MCPServerTask
    from tools.mcp_tool_registration import _register_server_tools
    from tools.registry import ToolRegistry

    registry = ToolRegistry()
    srv = MCPServerTask("github")
    srv.session = object()
    srv._tools = [_fake_tool(n) for n in tool_names]
    with patch("tools.registry.registry", registry), patch("tools.mcp_tool_registration._track_mcp_tool_server"):
        registered = _register_server_tools("github", srv, config)
    return registry, registered


def test_definition_is_hosted_read_only_with_a_token(github_entry):
    assert github_entry.transport.type == "http"
    assert github_entry.transport.url == "https://api.githubcopilot.com/mcp/"
    assert github_entry.transport.headers["X-MCP-Readonly"] == "true"
    assert set(github_entry.transport.headers["X-MCP-Toolsets"].split(",")) == {
        "repos", "issues", "pull_requests", "actions", "code_security"}
    assert github_entry.auth.type == "api_key"
    assert github_entry.env_keys == ["MCP_GITHUB_API_KEY"]
    cfg = mcp_catalog._build_server_config(github_entry, None)
    assert cfg["headers"]["Authorization"] == "Bearer ${MCP_GITHUB_API_KEY}"
    assert cfg["headers"]["X-MCP-Readonly"] == "true"


def test_allow_list_contains_no_write_tool_and_is_exact(github_entry):
    allowed = set(github_entry.tools.default_enabled)
    assert allowed.isdisjoint(WRITE_TOOLS)
    assert not any(name.startswith(("create_", "delete_", "push_", "merge_", "update_", "fork_", "add_"))
                   or name.endswith("_write") or name.endswith("_trigger") for name in allowed)
    assert {"get_file_contents", "list_pull_requests", "pull_request_read", "issue_read"} <= allowed


def test_write_tools_offered_by_the_server_are_hidden_and_refused(github_entry):
    config = mcp_catalog.card_install_config(github_entry)
    read_tools = list(github_entry.tools.default_enabled)
    registry, registered = _register([*read_tools, *WRITE_TOOLS, "brand_new_tool_from_a_server_update"], config)

    names = {r.removeprefix("mcp__github__") for r in registered}
    assert names >= set(read_tools)
    assert names.isdisjoint(WRITE_TOOLS)
    assert "brand_new_tool_from_a_server_update" not in names
    assert "error" in str(registry.dispatch("mcp__github__merge_pull_request", {"owner": "o", "repo": "r"})).lower()


def test_app_add_path_applies_the_allow_list(hermes_root, github_entry):
    _result(_call("mcp.servers.add", {"name": "github", "preset": "github"}))
    saved = yaml.safe_load((hermes_root / "config.yaml").read_text(encoding="utf-8"))["mcp_servers"]["github"]
    assert saved["tools"]["include"] == list(github_entry.tools.default_enabled)
    assert saved["headers"]["X-MCP-Readonly"] == "true"


def test_catalog_payload_asks_for_a_token_and_carries_the_setup_text(hermes_root):
    rows = {r["name"]: r for r in _result(_call("mcp.catalog"))["servers"]}
    assert rows["github"]["requires"] == ["MCP_GITHUB_API_KEY"]
    assert "Read-only" in rows["github"]["setup"]
    for scope in ("Contents", "Issues", "Pull requests", "Actions", "Metadata"):
        assert scope in rows["github"]["setup"]


def test_token_never_reaches_config_logs_or_model_visible_state(hermes_root, caplog):
    caplog.set_level(logging.DEBUG)
    _result(_call("mcp.servers.add", {"name": "github", "preset": "github"}))
    saved = _result(_call("mcp.servers.set_api_key", {
        "name": "github", "value": CANARY, "env_var": "MCP_GITHUB_API_KEY"}))

    config_text = (hermes_root / "config.yaml").read_text(encoding="utf-8")
    assert CANARY not in config_text
    assert CANARY in (hermes_root / ".env").read_text(encoding="utf-8")
    assert CANARY not in str(saved) and CANARY not in caplog.text
    assert CANARY not in str(_result(_call("mcp.servers.list"))) and CANARY not in str(_result(_call("mcp.catalog")))

    headers = yaml.safe_load(config_text)["mcp_servers"]["github"]["headers"]
    assert headers["Authorization"] == "Bearer ${MCP_GITHUB_API_KEY}"
    assert headers["X-MCP-Readonly"] == "true"


@pytest.mark.parametrize("platform", ["cli", "telegram", "acp"])
def test_session_kinds_get_github_tools_exactly_like_other_connectors(platform):
    from hermes_cli.tools_config import _get_platform_tools

    def enabled(server_name):
        config = {"mcp_servers": {server_name: {"url": "https://mcp.example.com/x", "enabled": True}}}
        return {t for t in _get_platform_tools(config, platform) if "mcp" in t}

    assert {t.replace("github", "other") for t in enabled("github")} == enabled("other")


@pytest.mark.asyncio
async def test_sign_in_event_asks_for_a_token_like_other_key_connectors(hermes_root, github_entry):
    from pathlib import Path

    from gateway.auth_flows import McpServerFlow

    _result(_call("mcp.servers.add", {"name": "github", "preset": "github"}))
    flow = McpServerFlow(Path(hermes_root), "mcp:github")
    await flow.begin()
    assert flow.kind == "api_key"
