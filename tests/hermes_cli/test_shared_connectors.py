from __future__ import annotations

import asyncio
import os
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import hermes_yaml as yaml
import pytest

from hermes_cli import shared_catalog
from hermes_cli.config import load_config
from hermes_cli.mcp_config import _get_mcp_servers, _remove_mcp_server, _save_mcp_server, mcp_command
from hermes_cli.shared_catalog import effective_mcp_servers, visible_mcp_servers
from hermes_cli.tools_config import _get_platform_tools, enabled_mcp_server_names
from tools.mcp_tool_common import mcp_server_enabled
from tools.mcp_oauth import HermesTokenStorage, RefreshFenceTimeout, acquire_refresh_fence, _refresh_lock_path
from tools.mcp_tool_config import connector_configs

URL = "https://mcp.upwork.com/mcp"
ACTION_POLICY = {"read_tools": ["search_jobs"], "refused_tools": ["fund_escrow"], "refused_message": "Use the website."}
GITHUB_URL = "https://api.githubcopilot.com/mcp/"
GITHUB_KEY = "MCP_GITHUB_API_KEY"
GITHUB = {"url": GITHUB_URL, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}
ROOT_ENTRY = {
    "enabled": True, "auth": "oauth", "signin_on": "owner_app", "accounts": {"default": {}},
    "action_policy": ACTION_POLICY, "connector_policy": {"write": "off"}, "tools": {"exclude": ["delete_everything"]},
}


class World:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.bot = root / "profiles" / "bot"
        self.other = root / "profiles" / "other"

    @contextmanager
    def acting_as(self, home: Path):
        previous = os.environ["HERMES_HOME"]
        os.environ["HERMES_HOME"] = str(home)
        try:
            yield
        finally:
            os.environ["HERMES_HOME"] = previous

    def write_servers(self, home: Path, servers: dict | None) -> None:
        doc = {"model": {}} if servers is None else {"model": {}, "mcp_servers": servers}
        (home / "config.yaml").write_text(yaml.safe_dump(doc, sort_keys=False))

    def servers(self, home: Path) -> dict:
        path = home / "config.yaml"
        return (yaml.safe_load(path.read_text()) or {}).get("mcp_servers") or {} if path.exists() else {}

    def env(self, home: Path) -> dict[str, str]:
        from agent.secret_scope import load_env_file

        return load_env_file(home / ".env")

    def put_env(self, home: Path, **values: str) -> None:
        (home / ".env").write_text("".join(f"{key}={value}\n" for key, value in values.items()))

    def token_files(self, home: Path) -> set[str]:
        base = home / "mcp-tokens"
        return {p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file()} if base.exists() else set()

    def put_tokens(self, name: str, home: Path, token: str = "tok", *, own: bool = False) -> None:
        from mcp.shared.auth import OAuthToken

        storage = HermesTokenStorage(name, hermes_home=home, **({"own_home_only": True} if own else {}))
        asyncio.run(storage.set_tokens(OAuthToken(access_token=token, token_type="Bearer", expires_in=3600)))


def make_world(tmp_path, monkeypatch) -> World:
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(root))
    w = World(root)
    for home in (w.bot, w.other):
        home.mkdir(parents=True)
        w.write_servers(home, None)
    catalog = root / "shared" / "catalog"
    catalog.mkdir(parents=True)
    (catalog / ".migrated").write_text("")
    (catalog / "mcp_servers.yaml").write_text(yaml.safe_dump({"upwork": {"url": URL}, "github": GITHUB}))
    w.write_servers(root, {"upwork": dict(ROOT_ENTRY)})
    return w


@pytest.fixture
def world(tmp_path, monkeypatch) -> World:
    return make_world(tmp_path, monkeypatch)


def effective(world: World, home: Path) -> dict:
    with world.acting_as(home):
        return effective_mcp_servers(load_config().get("mcp_servers"))


def visible(world: World, home: Path) -> dict:
    with world.acting_as(home):
        return visible_mcp_servers(load_config().get("mcp_servers"))


def discovered(world: World, home: Path, name: str = "upwork") -> dict:
    with world.acting_as(home):
        connections = connector_configs(name, interpolate=False)
    assert len(connections) <= 1, connections
    return next(iter(connections.values()), {})


def test_a_bot_with_no_entry_gets_the_shared_server_on_with_the_root_policies(world):
    for home in (world.bot, world.other):
        with world.acting_as(home):
            listed = _get_mcp_servers()["upwork"]
            names = enabled_mcp_server_names(load_config())
        views = (effective(world, home)["upwork"], visible(world, home)["upwork"], listed, discovered(world, home))
        for view in views:
            assert view["url"] == URL and view["enabled"] is True and view["auth"] == "oauth"
            assert view["action_policy"] == ACTION_POLICY and view["connector_policy"] == {"write": "off"}
            assert view["tools"] == {"exclude": ["delete_everything"]} and view["signin_on"] == "owner_app"
        assert "upwork" in names


def test_the_toolset_a_bot_resolves_includes_the_shared_server(world):
    with world.acting_as(world.bot):
        assert "upwork" in _get_platform_tools(load_config(), "cli")


def test_an_explicit_enabled_false_in_a_bot_does_not_switch_the_shared_server_off(world):
    world.write_servers(world.bot, {"upwork": {"enabled": False}})
    with world.acting_as(world.bot):
        assert effective(world, world.bot)["upwork"]["enabled"] is True
        assert discovered(world, world.bot)["action_policy"] == ACTION_POLICY
        assert "upwork" in enabled_mcp_server_names(load_config())


def test_a_bots_own_policy_cannot_loosen_the_roots(world):
    world.write_servers(world.bot, {"upwork": {"enabled": True, "action_policy": {"read_tools": ["fund_escrow"]}}})
    assert effective(world, world.bot)["upwork"]["action_policy"] == ACTION_POLICY


def test_with_the_root_entry_absent_the_bots_own_entry_applies_as_before(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth"}})
    assert effective(world, world.bot)["upwork"] == {"url": URL, "enabled": True, "auth": "oauth"}
    assert visible(world, world.other)["upwork"] == {"url": URL, "enabled": False}
    with world.acting_as(world.other):
        assert "upwork" not in enabled_mcp_server_names(load_config())


@pytest.mark.parametrize("root_entry", [{"enabled": False, "auth": "oauth", "action_policy": ACTION_POLICY}, {"auth": "oauth", "disabled": True}])
def test_a_server_the_root_owns_but_switched_off_is_off_for_every_bot_whatever_a_bot_says(world, root_entry):
    world.write_servers(world.root, {"upwork": root_entry})
    world.write_servers(world.bot, {"upwork": {"enabled": True}})
    for home in (world.bot, world.other):
        assert not mcp_server_enabled(effective(world, home)["upwork"])
        assert not mcp_server_enabled(visible(world, home)["upwork"])
        assert not mcp_server_enabled(discovered(world, home))
        assert "upwork" not in enabled_names_of(world, home)


def test_a_server_the_root_owns_that_the_catalog_never_heard_of_reaches_every_bot(world):
    world.write_servers(world.root, {"mine": {"url": "https://mine.example/mcp", "enabled": True}})
    for home in (world.bot, world.other):
        view = effective(world, home)["mine"]
        assert view["url"] == "https://mine.example/mcp" and view["enabled"] is True
        with world.acting_as(home):
            assert "mine" in enabled_mcp_server_names(load_config())
        assert discovered(world, home, "mine")["url"] == "https://mine.example/mcp"


def test_a_bot_created_after_the_connection_sees_every_enabled_server_the_root_owns(world):
    from hermes_cli.profiles import create_profile

    world.write_servers(world.root, {"upwork": dict(ROOT_ENTRY), "mine": {"url": "https://mine.example/mcp", "enabled": True}})
    create_profile("fresh", no_alias=True, no_skills=True)
    fresh = world.root / "profiles" / "fresh"
    with world.acting_as(fresh):
        names = enabled_mcp_server_names(load_config())
        assert {"upwork", "mine"} <= names
        assert HermesTokenStorage("mine")._tokens_path().resolve() == (world.root / "mcp-tokens" / "mine.json").resolve()
    assert discovered(world, fresh)["action_policy"] == ACTION_POLICY


def test_the_root_profile_reads_its_own_entry_unchanged(world):
    assert effective(world, world.root)["upwork"] == {"url": URL, **ROOT_ENTRY}


def test_a_shared_server_stores_its_oauth_state_in_the_root_whatever_the_profile_or_home(world):
    root_file = (world.root / "mcp-tokens" / "upwork.json").resolve()
    with world.acting_as(world.bot):
        assert HermesTokenStorage("upwork")._tokens_path().resolve() == root_file
    assert HermesTokenStorage("upwork", hermes_home=world.bot)._tokens_path().resolve() == root_file
    assert HermesTokenStorage("upwork", hermes_home=world.other)._tokens_path().resolve() == root_file
    account = HermesTokenStorage("upwork@work", hermes_home=world.bot)._tokens_path().resolve()
    assert account == (world.root / "mcp-tokens" / "accounts" / "upwork" / "work.json").resolve()


def test_a_server_the_root_does_not_own_keeps_its_oauth_state_per_profile(world):
    for name in ("mine", "other-custom"):
        stored = HermesTokenStorage(name, hermes_home=world.bot)._tokens_path().resolve()
        assert stored == (world.bot / "mcp-tokens" / f"{name}.json").resolve()


def test_a_connect_from_a_bots_connect_apps_writes_the_root_entry_and_the_root_tokens_for_any_server(world):
    with world.acting_as(world.bot):
        assert _save_mcp_server("upwork", {"url": URL, "auth": "oauth", "enabled": True, "connector_policy": {"read": "ask"}})
        assert _save_mcp_server("mine", {"url": "https://mine.example/mcp", "enabled": True})
        world.put_tokens("upwork", world.bot)
        world.put_tokens("mine", world.bot)
    assert world.servers(world.root)["upwork"]["connector_policy"] == {"read": "ask"}
    assert "mine" in world.servers(world.root)
    assert world.servers(world.bot) == {}
    assert world.token_files(world.root) == {"upwork.json", "mine.json"}
    assert world.token_files(world.bot) == set()
    assert "mine" in enabled_names_of(world, world.other)


def enabled_names_of(world: World, home: Path) -> set[str]:
    with world.acting_as(home):
        return enabled_mcp_server_names(load_config())


def test_a_disconnect_from_a_bot_removes_the_root_entry_and_every_bot_loses_access(world, monkeypatch):
    world.put_tokens("upwork", world.root)
    monkeypatch.setattr("builtins.input", lambda *_: "y")
    with world.acting_as(world.bot):
        mcp_command(SimpleNamespace(mcp_action="remove", name="upwork", everywhere=False))
    assert "upwork" not in world.servers(world.root)
    assert world.token_files(world.root) == set()
    for home in (world.bot, world.other):
        assert visible(world, home)["upwork"]["enabled"] is False
        assert discovered(world, home) == {}
        with world.acting_as(home):
            assert "upwork" not in enabled_mcp_server_names(load_config())


def test_removing_a_server_only_a_bot_has_removes_it_from_that_bot_and_leaves_the_root_alone(world):
    world.write_servers(world.bot, {"mine": {"url": "https://mine.example/mcp", "enabled": True}})
    with world.acting_as(world.bot):
        assert _remove_mcp_server("mine")
    assert "mine" not in world.servers(world.bot)
    assert world.servers(world.root)["upwork"] == ROOT_ENTRY


def test_two_profiles_refreshing_the_same_shared_server_use_one_token_file_and_one_lock(world):
    first = HermesTokenStorage("upwork", hermes_home=world.bot)._tokens_path()
    second = HermesTokenStorage("upwork", hermes_home=world.other)._tokens_path()
    assert first.resolve() == second.resolve()
    assert _refresh_lock_path(first) == _refresh_lock_path(second)

    from tools.mcp_oauth import release_refresh_fence

    async def contend() -> bool:
        held = await acquire_refresh_fence(first)
        try:
            await acquire_refresh_fence(second, timeout=0.3)
        except RefreshFenceTimeout:
            return True
        finally:
            release_refresh_fence(held)
        return False

    assert asyncio.run(contend()) is True


def adopt():
    from hermes_cli.shared_catalog_connectors import adopt_profile_connectors

    return adopt_profile_connectors()


def test_adoption_moves_a_profiles_login_and_entry_into_the_empty_root(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth", "action_policy": ACTION_POLICY}})
    world.put_tokens("upwork", world.bot, "bot-token", own=True)
    world.put_tokens("upwork@work", world.bot, "work-token", own=True)
    assert world.token_files(world.bot) == {"upwork.json", "accounts/upwork/work.json"}

    adopt()

    assert world.token_files(world.root) == {"upwork.json", "accounts/upwork/work.json"}
    assert world.token_files(world.bot) == set()
    assert world.servers(world.root)["upwork"]["action_policy"] == ACTION_POLICY
    with world.acting_as(world.other):
        assert HermesTokenStorage("upwork").has_cached_tokens()
        assert "upwork" in enabled_mcp_server_names(load_config())


def test_adoption_never_overwrites_state_the_root_already_has(world):
    world.put_tokens("upwork", world.root, "root-token")
    world.put_tokens("upwork", world.bot, "bot-token", own=True)
    before = (world.root / "mcp-tokens" / "upwork.json").read_bytes()

    adopt()

    assert (world.root / "mcp-tokens" / "upwork.json").read_bytes() == before
    assert world.servers(world.root)["upwork"] == ROOT_ENTRY
    assert world.token_files(world.bot) == {"upwork.json"}


def test_adoption_is_repeatable_and_a_second_profile_does_not_overwrite_the_first(world):
    world.write_servers(world.root, {})
    world.put_tokens("upwork", world.bot, "bot-token", own=True)
    world.put_tokens("upwork", world.other, "other-token", own=True)

    adopt()
    adopted = (world.root / "mcp-tokens" / "upwork.json").read_bytes()
    snapshot = (world.token_files(world.root), world.token_files(world.bot), world.token_files(world.other))
    adopt()

    assert "bot-token" in adopted.decode()
    assert (world.root / "mcp-tokens" / "upwork.json").read_bytes() == adopted
    assert snapshot == (world.token_files(world.root), world.token_files(world.bot), world.token_files(world.other))
    assert world.token_files(world.other) == {"upwork.json"}


def test_adoption_leaves_a_custom_servers_login_with_its_profile(world):
    world.put_tokens("mine", world.bot, own=True)
    adopt()
    assert world.token_files(world.bot) == {"mine.json"} and world.token_files(world.root) == set()


def test_a_bot_never_migrates_the_roots_legacy_login_into_its_own_config(world):
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth"}})
    world.put_tokens("upwork", world.root)
    discovered(world, world.bot)
    assert world.servers(world.bot) == {"upwork": {"enabled": True, "auth": "oauth"}}


def test_the_discovery_config_a_bot_connects_with_carries_the_roots_refusal_of_money_steps(world):
    from tools import mcp_action_gate

    config = discovered(world, world.bot)
    policy = mcp_action_gate.policy_from_config(config)
    assert policy is not None
    assert policy.classify("fund_escrow") == mcp_action_gate.REFUSED
    assert policy.classify("search_jobs") == mcp_action_gate.READ


def cli_add(monkeypatch, name: str, url: str, key: str) -> None:
    from hermes_cli import mcp_config

    monkeypatch.setattr(mcp_config, "_confirm", lambda *_a, **_k: True)
    monkeypatch.setattr(mcp_config, "_probe_single_server", lambda *_a, **_k: [("search_repos", "Search")])
    monkeypatch.setattr(mcp_config, "_choose_tools", lambda *_a, **_k: 1)
    monkeypatch.setattr("hermes_cli.cli_output.prompt", lambda *_a, **_k: key)
    mcp_command(SimpleNamespace(
        mcp_action="add", name=name, url=url, mcp_command=None, args=[], auth="header", preset=None,
        env=None, replace_shared=False, connect_timeout=None))


def add_github_with_a_header_key(monkeypatch, key: str) -> None:
    cli_add(monkeypatch, "github", GITHUB_URL, key)


def test_adding_a_header_key_server_from_a_bot_cli_writes_the_roots_env_and_entry(world, monkeypatch):
    world.write_servers(world.root, {})
    with world.acting_as(world.bot):
        add_github_with_a_header_key(monkeypatch, "ghp_from_bot")
    assert world.env(world.root) == {GITHUB_KEY: "ghp_from_bot"}
    assert world.env(world.bot) == {}
    assert world.servers(world.root)["github"]["headers"] == {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}
    assert "github" not in world.servers(world.bot)


def test_adoption_copies_a_key_servers_entry_and_the_keys_it_references_into_the_root(world):
    world.write_servers(world.root, {})
    bot_entry = {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}
    world.write_servers(world.bot, {"github": bot_entry})
    world.put_env(world.bot, **{GITHUB_KEY: "bot-key", "UNRELATED": "keep-out"})

    adopt()

    assert world.servers(world.root)["github"] == bot_entry
    assert world.env(world.root) == {GITHUB_KEY: "bot-key"}
    assert world.env(world.bot) == {GITHUB_KEY: "bot-key", "UNRELATED": "keep-out"}
    with world.acting_as(world.other):
        assert "github" in enabled_mcp_server_names(load_config())


def test_adoption_never_overwrites_a_key_the_root_already_has(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    world.put_env(world.root, **{GITHUB_KEY: "root-key"})
    world.put_env(world.bot, **{GITHUB_KEY: "bot-key"})

    adopt()

    assert world.env(world.root) == {GITHUB_KEY: "root-key"}
    assert "github" in world.servers(world.root)


def test_adoption_of_a_key_server_is_repeatable_and_the_first_profile_wins(world):
    world.write_servers(world.root, {})
    for home, key in ((world.bot, "bot-key"), (world.other, "other-key")):
        world.write_servers(home, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
        world.put_env(home, **{GITHUB_KEY: key})

    adopt()
    snapshot = ((world.root / "config.yaml").read_bytes(), (world.root / ".env").read_bytes())
    adopt()

    assert world.env(world.root) == {GITHUB_KEY: "bot-key"}
    assert snapshot == ((world.root / "config.yaml").read_bytes(), (world.root / ".env").read_bytes())


def test_adoption_never_logs_a_secret_value(world, caplog):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    world.put_env(world.bot, **{GITHUB_KEY: "super-secret-value"})
    with caplog.at_level("DEBUG"):
        adopt()
    assert "super-secret-value" not in caplog.text


def test_a_bot_sees_a_shared_key_server_as_connected_when_the_roots_key_is_set(world):
    from hermes_cli.mcp_accounts import CONNECTED, NOT_CONNECTED, connection_state

    world.write_servers(world.root, {"github": {"enabled": True}})
    with world.acting_as(world.bot):
        cfg = effective_mcp_servers(load_config().get("mcp_servers"))["github"]
        assert connection_state("github", cfg)[0] == NOT_CONNECTED
        world.put_env(world.root, **{GITHUB_KEY: "root-key"})
        assert connection_state("github", cfg)[0] == CONNECTED


def test_a_bots_own_key_does_not_make_a_shared_key_server_look_connected(world):
    from hermes_cli.mcp_accounts import NOT_CONNECTED, connection_state

    world.write_servers(world.root, {"github": {"enabled": True}})
    world.put_env(world.bot, **{GITHUB_KEY: "bot-key"})
    with world.acting_as(world.bot):
        cfg = effective_mcp_servers(load_config().get("mcp_servers"))["github"]
        assert connection_state("github", cfg)[0] == NOT_CONNECTED


def test_adoption_skips_a_key_server_whose_key_neither_the_profile_nor_the_root_holds(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    adopt()
    assert world.servers(world.root) == {}


def test_adoption_skips_a_key_server_a_profile_switched_off(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"github": {"enabled": False, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    world.put_env(world.bot, **{GITHUB_KEY: "bot-key"})
    adopt()
    assert world.servers(world.root) == {} and world.env(world.root) == {}


def test_an_owner_adding_a_custom_server_from_a_bots_terminal_publishes_it_to_every_bot_through_the_root(world, monkeypatch):
    with world.acting_as(world.bot):
        cli_add(monkeypatch, "mine", "https://mine.example/mcp", "owner-key")
    assert "mine" in world.servers(world.root) and world.servers(world.bot) == {}
    assert world.env(world.root) == {"MCP_MINE_API_KEY": "owner-key"} and world.env(world.bot) == {}
    assert "mine" in enabled_names_of(world, world.other)


def test_a_pass_with_nothing_to_adopt_still_closes_adoption_so_a_later_bot_only_server_is_never_promoted(world):
    world.write_servers(world.root, {})
    adopt()
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth"}})
    world.put_tokens("upwork", world.bot, "bot-token", own=True)
    world.write_servers(world.other, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    world.put_env(world.other, **{GITHUB_KEY: "other-key"})

    assert adopt() == []

    assert world.servers(world.root) == {} and world.env(world.root) == {}
    assert world.token_files(world.root) == set() and world.token_files(world.bot) == {"upwork.json"}
    assert "upwork" not in enabled_names_of(world, world.other) and "github" not in enabled_names_of(world, world.bot)


def test_adoption_takes_what_profiles_held_before_and_ignores_a_bot_only_server_made_after_it_closed(world):
    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth"}})
    world.put_tokens("upwork", world.bot, "bot-token", own=True)

    assert adopt() == [("bot", "upwork")]
    assert world.token_files(world.root) == {"upwork.json"} and "upwork" in world.servers(world.root)

    world.write_servers(world.other, {"github": {"enabled": True, "headers": {"Authorization": f"Bearer ${{{GITHUB_KEY}}}"}}})
    world.put_env(world.other, **{GITHUB_KEY: "other-key"})
    world.put_tokens("github", world.other, "other-token", own=True)
    assert adopt() == []
    assert "github" not in world.servers(world.root) and world.env(world.root) == {}
    assert world.token_files(world.other) == {"github.json"}


def test_a_failed_adoption_pass_does_not_close_adoption(world, monkeypatch):
    from hermes_cli import shared_catalog_connectors as connectors

    world.write_servers(world.root, {})
    world.write_servers(world.bot, {"upwork": {"enabled": True, "auth": "oauth"}})
    real = connectors._adopt_entry

    def failing(*_a, **_k):
        raise OSError("disk went away")

    monkeypatch.setattr(connectors, "_adopt_entry", failing)
    with pytest.raises(OSError):
        adopt()
    monkeypatch.setattr(connectors, "_adopt_entry", real)

    adopt()
    assert "upwork" in world.servers(world.root)
