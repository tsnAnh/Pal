from __future__ import annotations

import asyncio
import os
from pathlib import Path

import hermes_yaml as yaml
import pytest

from hermes_cli.profiles import create_profile
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

URL = "https://mcp.upwork.com/mcp"
ACTION_POLICY = {"read_tools": ["search_jobs"], "refused_tools": ["fund_escrow"]}
GITHUB_KEY = "MCP_GITHUB_API_KEY"
GITHUB = {"url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}


@pytest.fixture
def world(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr(server, "_hermes_home", root)
    monkeypatch.setattr(sessions, "_sessions", {})
    for name in ("bot", "other"):
        create_profile(name, no_alias=True, no_skills=True)
    catalog = root / "shared" / "catalog"
    catalog.mkdir(parents=True)
    (catalog / ".migrated").write_text("")
    (catalog / "mcp_servers.yaml").write_text(yaml.safe_dump({"upwork": {"url": URL}, "github": GITHUB}))
    return root


def home_of(root: Path, profile: str) -> Path:
    return root if profile == "default" else root / "profiles" / profile


def servers_of(root: Path, profile: str) -> dict:
    path = home_of(root, profile) / "config.yaml"
    return (yaml.safe_load(path.read_text()) or {}).get("mcp_servers") or {} if path.exists() else {}


def rpc(method: str, **params) -> dict:
    return server._methods[method](1, params)


def listed(profile: str) -> dict:
    return {s["name"]: s for s in rpc("mcp.servers.list", profile=profile)["result"]["servers"]}


def test_an_add_from_a_bot_writes_the_root_entry_and_every_bot_sees_the_app(world):
    reply = rpc("mcp.servers.add", name="upwork", profile="bot", config={"url": URL, "transport": "http"})
    assert reply["result"]["ok"] is True, reply
    assert "upwork" in servers_of(world, "default") and "upwork" not in servers_of(world, "bot")
    assert listed("other")["upwork"]["enabled"] is True and listed("bot")["upwork"]["enabled"] is True


def test_a_custom_server_added_from_a_bots_connect_apps_is_owned_by_the_root_and_every_bot_sees_it(world):
    reply = rpc("mcp.servers.add", name="mine", profile="bot", config={"url": "https://mine.example/mcp", "transport": "http"})
    assert reply["result"]["ok"] is True, reply
    assert "mine" in servers_of(world, "default") and "mine" not in servers_of(world, "bot")
    assert listed("other")["mine"]["enabled"] is True and listed("bot")["mine"]["enabled"] is True


def test_the_oauth_tokens_of_a_custom_server_added_from_a_bot_land_in_the_root_and_another_bot_uses_them(world):
    from mcp.shared.auth import OAuthToken

    from tools.mcp_oauth import HermesTokenStorage

    rpc("mcp.servers.add", name="mine", profile="bot", config={"url": "https://mine.example/mcp", "transport": "http"})
    asyncio.run(HermesTokenStorage("mine", hermes_home=home_of(world, "bot")).set_tokens(
        OAuthToken(access_token="tok", token_type="Bearer", expires_in=3600)))
    assert (world / "mcp-tokens" / "mine.json").is_file()
    assert not (world / "profiles" / "bot" / "mcp-tokens").exists()
    assert HermesTokenStorage("mine", hermes_home=home_of(world, "other")).has_cached_tokens()


def test_an_oauth_start_from_a_bot_runs_under_the_roots_home(world, monkeypatch):
    started = {}

    def start_flow(hermes_home, connection, cfg, **_):
        started.update(home=Path(hermes_home).resolve(), connection=connection)
        return {"session_id": "s1", "auth_url": "https://as.example/authorize", "flow": "pkce"}

    monkeypatch.setattr(sessions, "start_flow", start_flow)
    reply = rpc("mcp.servers.oauth.start", name="upwork", profile="bot")
    assert reply["result"]["ok"] is True, reply
    assert started == {"home": world.resolve(), "connection": "upwork@default"}


def test_an_oauth_start_for_a_custom_server_added_from_a_bot_runs_under_the_roots_home(world, monkeypatch):
    rpc("mcp.servers.add", name="mine", profile="bot", config={"url": "https://mine.example/mcp", "transport": "http"})
    started = {}

    def start_flow(hermes_home, connection, cfg, **_):
        started.update(home=Path(hermes_home).resolve())
        return {"session_id": "s1", "auth_url": "https://as.example/authorize", "flow": "pkce"}

    monkeypatch.setattr(sessions, "start_flow", start_flow)
    assert rpc("mcp.servers.oauth.start", name="mine", profile="bot")["result"]["ok"] is True
    assert started == {"home": world.resolve()}


def test_an_oauth_start_for_a_server_only_the_bot_has_runs_under_the_bots_home(world, monkeypatch):
    bot = home_of(world, "bot")
    (bot / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {"mine": {"url": "https://mine.example/mcp", "enabled": True}}}))
    started = {}

    def start_flow(hermes_home, connection, cfg, **_):
        started.update(home=Path(hermes_home).resolve())
        return {"session_id": "s1", "auth_url": "https://as.example/authorize", "flow": "pkce"}

    monkeypatch.setattr(sessions, "start_flow", start_flow)
    assert rpc("mcp.servers.oauth.start", name="mine", profile="bot")["result"]["ok"] is True
    assert started == {"home": bot.resolve()}


def test_a_policy_change_from_a_bot_edits_the_root_entry(world):
    rpc("mcp.servers.add", name="upwork", profile="default", config={"url": URL, "transport": "http"})
    entry = servers_of(world, "default")["upwork"]
    entry.update(auth="oauth", action_policy=ACTION_POLICY)
    (world / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {"upwork": entry}}))

    reply = rpc("connectors.details.policy.set", slug="upwork", group="read", mode="ask", profile="bot")
    assert "error" not in reply, reply
    assert servers_of(world, "default")["upwork"]["connector_policy"] == {"read": "ask"}
    assert "upwork" not in servers_of(world, "bot")


def test_a_disconnect_from_a_bot_removes_the_app_for_every_bot(world):
    rpc("mcp.servers.add", name="upwork", profile="bot", config={"url": URL, "transport": "http"})
    assert listed("other")["upwork"]["enabled"] is True

    reply = rpc("mcp.servers.remove", name="upwork", profile="bot")
    assert reply["result"]["ok"] is True, reply
    assert "upwork" not in servers_of(world, "default")
    for profile in ("bot", "other", "default"):
        assert listed(profile)["upwork"]["enabled"] is False


def env_of(root: Path, profile: str) -> dict[str, str]:
    from agent.secret_scope import load_env_file

    return load_env_file(home_of(root, profile) / ".env")


def test_a_key_saved_from_a_bot_lands_in_the_roots_env_and_entry_not_the_bots(world):
    reply = rpc("mcp.servers.set_api_key", name="github", profile="bot", value="ghp_secret")
    assert reply["result"]["ok"] is True, reply
    assert list(env_of(world, "default").values()) == ["ghp_secret"]
    assert env_of(world, "bot") == {}
    assert "github" in servers_of(world, "default") and "github" not in servers_of(world, "bot")
    assert not any(value == "ghp_secret" for value in os.environ.values())
    recorded = servers_of(world, "default")["github"]["accounts"]["default"]["api_key_env"]
    assert list(env_of(world, "default")) == [recorded]


def test_a_key_saved_for_a_custom_server_from_a_bots_connect_apps_lands_in_the_roots_env(world):
    rpc("mcp.servers.add", name="mine", profile="bot", config={"url": "https://mine.example/mcp", "transport": "http"})
    reply = rpc("mcp.servers.set_api_key", name="mine", profile="bot", value="mine-secret")
    assert reply["result"]["ok"] is True, reply
    assert list(env_of(world, "default").values()) == ["mine-secret"]
    assert env_of(world, "bot") == {}


