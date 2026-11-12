"""Manifest-driven action gate and owner-computer sign-in of a catalog MCP server (``optional-mcps/upwork``)."""

import pytest

from hermes_cli import mcp_catalog
from tools import mcp_action_gate

BASE = """manifest_version: 1
name: demo
description: Demo server
transport: {type: http, url: "https://demo.example/mcp"}
"""


def _parse(tmp_path, body):
    path = tmp_path / "manifest.yaml"
    path.write_text(BASE + body)
    return mcp_catalog._parse_manifest(path)


def test_the_manifest_policy_reaches_the_installed_server_block_unchanged():
    entry = mcp_catalog.get_entry("upwork")
    cfg = mcp_catalog._build_server_config(entry, None)
    assert cfg["url"] == "https://mcp.upwork.com/mcp" and cfg["auth"] == "oauth" and cfg["signin_on"] == "owner_computer"
    policy = mcp_action_gate.policy_from_config(cfg)
    assert policy.read_tools == frozenset(entry.action_policy.read_tools)
    assert "upwork.com" in policy.refused_message


@pytest.mark.parametrize("entry", [e for e in mcp_catalog.list_catalog() if e.action_policy is not None],
                         ids=lambda e: e.name)
def test_no_declared_read_tool_is_also_a_refused_step(entry):
    policy = mcp_action_gate.policy_from_config(mcp_catalog._build_server_config(entry, None))
    assert policy.read_tools and policy.refused_patterns
    assert all(policy.classify(name) == mcp_action_gate.READ for name in policy.read_tools)


def test_a_server_without_a_policy_gets_no_gate_key(tmp_path):
    entry = _parse(tmp_path, "auth: {type: none}\n")
    assert "action_policy" not in mcp_catalog._build_server_config(entry, None)
    assert mcp_action_gate.policy_from_config(mcp_catalog._build_server_config(entry, None)) is None


@pytest.mark.parametrize("body", [
    "action_policy: nope\n",
    "action_policy: {read_tools: search}\n",
    "action_policy: {read_tools: [a], bogus: 1}\n",
    "action_policy: {refused_message: 3}\n",
    "auth: {type: api_key, signin_on: owner_computer}\n",
    "auth: {type: oauth, signin_on: elsewhere}\n",
])
def test_a_malformed_policy_or_sign_in_declaration_is_a_manifest_error(tmp_path, body):
    with pytest.raises(mcp_catalog.CatalogError):
        _parse(tmp_path, body)


def test_discovery_records_the_policy_per_server_and_a_removed_scope_forgets_it():
    from types import SimpleNamespace
    from tools import mcp_tool, mcp_tool_registration as registration
    cfg = mcp_catalog._build_server_config(mcp_catalog.get_entry("upwork"), None)
    registration._record_tool_trust_metadata("upwork", cfg, [SimpleNamespace(name="search_jobs", annotations=None)])
    try:
        assert isinstance(mcp_tool._server_action_policies["upwork"], mcp_action_gate.ActionPolicy)
        registration._record_tool_trust_metadata("upwork", {"url": cfg["url"]}, [])
        assert "upwork" not in mcp_tool._server_action_policies
    finally:
        mcp_tool._server_action_policies.pop("upwork", None)
        mcp_tool._tool_read_only_hints.pop("upwork", None)
        mcp_tool._server_trust_levels.pop("upwork", None)
