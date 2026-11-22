from __future__ import annotations

from pathlib import Path

import hermes_yaml as yaml
import pytest
from starlette.testclient import TestClient

from agent.secret_scope import load_env_file
from hermes_cli.config import invalidate_env_cache, load_config
from hermes_cli.profiles import create_profile
from hermes_cli.shared_catalog import effective_mcp_servers
from hermes_cli.tools_config import enabled_mcp_server_names
from hermes_cli.web_server import _SESSION_HEADER_NAME, _SESSION_TOKEN, app
from tests.hermes_cli.test_shared_connectors import World

MINE = "https://mine.example/mcp"
DEMO_KEY = "DEMO_API_KEY"


@pytest.fixture
def world(tmp_path, monkeypatch) -> World:
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    for name in ("bot", "other"):
        create_profile(name, no_alias=True, no_skills=True)
    catalog = root / "shared" / "catalog"
    catalog.mkdir(parents=True)
    (catalog / ".migrated").write_text("")
    return World(root)


@pytest.fixture
def client(world):
    with TestClient(app) as test_client:
        test_client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
        yield test_client


@pytest.fixture
def demo_catalog(tmp_path, monkeypatch):
    entry_dir = tmp_path / "optional-mcps" / "demo"
    entry_dir.mkdir(parents=True)
    (entry_dir / "manifest.yaml").write_text(yaml.safe_dump({
        "manifest_version": 1, "name": "demo", "description": "Synthetic dashboard fixture",
        "source": "https://example.test/demo",
        "transport": {"type": "stdio", "command": "demo-mcp"},
        "auth": {"type": "api_key", "env": [{"name": DEMO_KEY, "prompt": "Demo API key", "secret": True}]},
    }))
    monkeypatch.setenv("HERMES_OPTIONAL_MCPS", str(tmp_path / "optional-mcps"))
    invalidate_env_cache()


def enabled_for(world: World, home: Path) -> set[str]:
    with world.acting_as(home):
        return enabled_mcp_server_names(load_config())


def test_a_server_added_in_a_bots_dashboard_lands_in_the_root_with_its_key_and_every_bot_sees_it(world, client):
    response = client.post(
        "/api/mcp/servers", params={"profile": "bot"},
        json={"name": "mine", "url": MINE, "auth": "header", "bearer_token": "owner-secret"})
    assert response.status_code == 200, response.text

    assert world.servers(world.root)["mine"]["headers"] == {"Authorization": "Bearer ${MCP_MINE_API_KEY}"}
    assert world.env(world.root) == {"MCP_MINE_API_KEY": "owner-secret"}
    assert world.servers(world.bot) == {} and world.env(world.bot) == {}

    create_profile("fresh", no_alias=True, no_skills=True)
    for home in (world.bot, world.other, world.root / "profiles" / "fresh"):
        assert "mine" in enabled_for(world, home)
        with world.acting_as(home):
            assert effective_mcp_servers(load_config().get("mcp_servers"))["mine"]["url"] == MINE


def test_a_catalog_install_from_a_bots_dashboard_writes_the_roots_entry_and_key(world, client, demo_catalog):
    response = client.post(
        "/api/mcp/catalog/install", params={"profile": "bot"},
        json={"name": "demo", "env": {DEMO_KEY: "demo-secret"}})
    assert response.status_code == 200, response.text

    assert "demo" in world.servers(world.root)
    assert load_env_file(world.root / ".env") == {DEMO_KEY: "demo-secret"}
    assert world.servers(world.bot) == {} and load_env_file(world.bot / ".env") == {}
    assert "demo" in enabled_for(world, world.other)


def test_a_bots_dashboard_can_switch_off_and_remove_a_server_the_root_owns(world, client):
    world.write_servers(world.root, {"mine": {"url": MINE, "enabled": True}})

    off = client.put("/api/mcp/servers/mine/enabled", params={"profile": "bot"}, json={"enabled": False})
    assert off.status_code == 200, off.text
    assert world.servers(world.root)["mine"]["enabled"] is False
    assert "mine" not in enabled_for(world, world.other)

    removed = client.delete("/api/mcp/servers/mine", params={"profile": "bot"})
    assert removed.status_code == 200, removed.text
    assert world.servers(world.root) == {}
    assert "mine" not in enabled_for(world, world.other)


def test_a_server_only_a_bot_has_stays_manageable_from_that_bots_dashboard_without_reaching_the_root(world, client):
    world.write_servers(world.bot, {"mine": {"url": MINE, "enabled": True}})

    off = client.put("/api/mcp/servers/mine/enabled", params={"profile": "bot"}, json={"enabled": False})
    assert off.status_code == 200, off.text
    assert world.servers(world.bot)["mine"]["enabled"] is False
    assert world.servers(world.root) == {}


def test_hermes_mcp_install_from_a_bots_terminal_writes_the_roots_entry_and_key(world, demo_catalog, monkeypatch):
    from types import SimpleNamespace

    from hermes_cli import mcp_catalog
    from hermes_cli.mcp_config import mcp_command

    monkeypatch.setattr(mcp_catalog, "_prompt_input", lambda *_a, **_k: "terminal-secret")
    with world.acting_as(world.bot):
        mcp_command(SimpleNamespace(mcp_action="install", identifier="demo"))
    assert "demo" in world.servers(world.root)
    assert load_env_file(world.root / ".env") == {DEMO_KEY: "terminal-secret"}
    assert world.servers(world.bot) == {} and load_env_file(world.bot / ".env") == {}
    assert "demo" in enabled_for(world, world.other)


def test_the_interactive_picker_toggles_the_roots_entry_for_a_server_the_root_owns(world):
    from hermes_cli import mcp_picker

    world.write_servers(world.root, {"mine": {"url": MINE, "enabled": True}})
    with world.acting_as(world.bot):
        mcp_picker._enable_disable("mine", enable=False)
    assert world.servers(world.root)["mine"]["enabled"] is False and world.servers(world.bot) == {}
    assert "mine" not in enabled_for(world, world.other)


def test_hermes_tools_filters_for_a_server_the_root_owns_land_in_the_roots_entry(world):
    from types import SimpleNamespace

    from hermes_cli.tools_config_mcp import tools_disable_enable_command

    world.write_servers(world.root, {"mine": {"url": MINE, "enabled": True}})
    world.write_servers(world.bot, {"keep": {"url": MINE, "enabled": True}})
    with world.acting_as(world.bot):
        tools_disable_enable_command(SimpleNamespace(tools_action="disable", names=["mine:delete_all", "keep:drop"], platform="cli"))
    assert world.servers(world.root)["mine"]["tools"] == {"exclude": ["delete_all"]}
    assert world.servers(world.bot)["keep"]["tools"] == {"exclude": ["drop"]}
    assert "mine" not in world.servers(world.bot)


def test_a_bots_agent_cannot_change_the_tool_filters_of_a_server_the_root_owns(world, monkeypatch):
    from types import SimpleNamespace

    from hermes_cli.profile_admin_guard import AGENT_TOOL_MARKER_ENV
    from hermes_cli.tools_config_mcp import tools_disable_enable_command

    owned = {"url": MINE, "enabled": True}
    world.write_servers(world.root, {"mine": dict(owned)})
    monkeypatch.setenv(AGENT_TOOL_MARKER_ENV, "1")
    with world.acting_as(world.bot):
        tools_disable_enable_command(SimpleNamespace(tools_action="disable", names=["mine:delete_all"], platform="cli"))
    assert world.servers(world.root) == {"mine": owned}


def test_enabling_a_connector_from_a_bots_chat_flips_the_roots_entry(world):
    from tools.connectors.mcp import _CatalogBackend

    world.write_servers(world.root, {"mine": {"url": MINE, "enabled": False}})
    with world.acting_as(world.bot):
        _CatalogBackend().enable("mine")
    assert world.servers(world.root)["mine"].get("enabled") is True
    assert world.servers(world.bot) == {}
    assert "mine" in enabled_for(world, world.other)


def test_a_card_oauth_for_a_new_server_runs_and_stores_its_state_under_the_roots_home(world, monkeypatch):
    from tools.connectors import mcp_oauth

    seen = {}

    def worker(hermes_home, server_name, cfg, reconnect_live, *, flow, **_):
        seen["home"] = Path(hermes_home).resolve()
        flow.mark_approved()
        flow.mark_worker_done()

    monkeypatch.setattr(mcp_oauth, "run_worker", worker)
    with world.acting_as(world.bot):
        attempt = mcp_oauth.start("mine", cfg={"url": MINE, "enabled": True})
    assert attempt.auth_url == "" and seen["home"] == world.root.resolve()


def test_a_card_oauth_for_a_server_only_the_bot_has_runs_under_the_bots_home(world, monkeypatch):
    from tools.connectors import mcp_oauth

    world.write_servers(world.bot, {"mine": {"url": MINE, "enabled": True}})
    seen = {}

    def worker(hermes_home, server_name, cfg, reconnect_live, *, flow, **_):
        seen["home"] = Path(hermes_home).resolve()
        flow.mark_approved()
        flow.mark_worker_done()

    monkeypatch.setattr(mcp_oauth, "run_worker", worker)
    with world.acting_as(world.bot):
        mcp_oauth.start("mine", cfg={"url": MINE, "enabled": True})
    assert seen["home"] == world.bot.resolve()
