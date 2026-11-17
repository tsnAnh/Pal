import logging

import httpx
import pytest

from gateway import connector_setup_checks as checks
from tui_gateway import server

TOKEN = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"
BOT_ID = "101010101010101010"
GUILDS = [{"id": "111", "name": "Team"}, {"id": "222", "name": "Friends"}]
READ_INVITE = f"https://discord.com/oauth2/authorize?client_id={BOT_ID}&scope=bot&permissions=66560"


@pytest.fixture
def home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    (root / "profiles" / "work").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.__init__",
                        lambda *_a, **_k: pytest.fail("reached the Nous Portal"))
    return root / "profiles" / "work"


@pytest.fixture
def discord(monkeypatch):
    state = {"me": {"id": BOT_ID, "username": "palbot", "bot": True}, "guilds": GUILDS, "seen": []}

    def handle(request):
        assert request.url.host == "discord.com"
        state["seen"].append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != f"Bot {TOKEN}":
            return httpx.Response(401, json={"message": "401: Unauthorized"})
        if request.url.path == "/api/v10/users/@me":
            return httpx.Response(200, json=state["me"])
        if request.url.path == "/api/v10/users/@me/guilds":
            return httpx.Response(200, json=state["guilds"])
        return httpx.Response(404)

    monkeypatch.setattr(checks, "default_transport", httpx.MockTransport(handle))
    return state


@pytest.fixture
def handshake(monkeypatch):
    state = {"tools": [("discord_list_guilds", ""), ("discord_read_messages", "")], "configs": [], "restarts": 0}

    def probe(name, cfg, *_a, **_k):
        state["configs"].append((name, cfg))
        if isinstance(state["tools"], Exception):
            raise state["tools"]
        return state["tools"]

    monkeypatch.setattr("hermes_cli.mcp_config._probe_single_server", probe)
    monkeypatch.setattr("tui_gateway.discord_connector._restart_live",
                        lambda: state.__setitem__("restarts", state["restarts"] + 1))
    return state


def _call(method, **params):
    return server._methods[method](1, {"profile": "work", **params})


def _ok(method, **params):
    response = _call(method, **params)
    assert "error" not in response, response
    return response["result"]


def _reason(response):
    return response["error"]["data"]["reason"]


def _row():
    return {r["slug"]: r for r in _ok("connectors.catalog")["connectors"]}["discord"]


def _item(value):
    return _ok("vault.add", kind="api_key", label="pasted", secret={"api_key": value})["id"]


def _connect_token():
    return _ok("connectors.discord.token", item=_item(TOKEN))


def _files(home):
    return "".join(p.read_text() for p in home.rglob("*") if p.is_file() and p.suffix in (".yaml", ".json"))


@pytest.mark.parametrize("pasted", ["not-a-token", "Bot " + TOKEN, TOKEN.replace(".", "")])
def test_a_badly_shaped_token_is_refused_without_calling_discord(home, discord, pasted):
    result = _ok("connectors.setup.check", slug="discord", values={"token": _item(pasted)})

    assert (result["ok"], result["reason"]) == (False, "INVALID_TOKEN")
    assert discord["seen"] == []


def test_the_check_proves_the_token_with_discord_and_shows_only_the_bot_name(home, discord, caplog):
    caplog.set_level(logging.DEBUG)

    result = _ok("connectors.setup.check", slug="discord", values={"token": _item(TOKEN)})

    assert result == {"slug": "discord", "ok": True, "reason": None, "message": None, "account": "palbot"}
    assert discord["seen"] == [("/api/v10/users/@me", f"Bot {TOKEN}")]
    assert TOKEN not in caplog.text and TOKEN not in str(result)


def test_a_user_account_token_is_refused(home, discord):
    discord["me"] = {"id": BOT_ID, "username": "a-person"}

    assert _ok("connectors.setup.check", slug="discord", values={"token": _item(TOKEN)})["reason"] == "INVALID_TOKEN"
    assert _reason(_call("connectors.discord.token", item=_item(TOKEN))) == "INVALID_TOKEN"


def test_before_a_token_the_guide_hides_the_invite_links_and_starts_at_the_bot_step(home):
    row = _row()
    steps = {s["id"]: s for s in row["setup_guide"]["steps"]}

    assert (row["method"], row["status"]) == ("bot_token_stdio", "not_connected")
    assert steps["invite"]["links"] == []
    assert row["setup_progress"] == {"step_id": "bot", "saved": []}
    assert _reason(_call("connectors.discord.guilds")) == "NEEDS_SETUP"


def test_the_saved_token_lives_only_in_the_profile_env_and_fills_the_invite_link(home, discord):
    assert _connect_token() == {"bot_name": "palbot", "application_id": BOT_ID}
    row = _row()
    links = {s["id"]: s for s in row["setup_guide"]["steps"]}["invite"]["links"]

    assert f"DISCORD_TOKEN={TOKEN}" in (home / ".env").read_text()
    assert TOKEN not in _files(home) and TOKEN not in str(row)
    assert [link["url"] for link in links] == [READ_INVITE, READ_INVITE.replace("66560", "68672")]
    assert row["setup_progress"] == {"step_id": "invite", "saved": ["token"]}


def test_the_server_list_comes_live_from_discord(home, discord):
    _connect_token()

    assert _ok("connectors.discord.guilds") == {"guilds": GUILDS, "allowed": [], "read_only": True}


@pytest.mark.parametrize("guild_ids", [[], ["999"], ["111", "999"]])
def test_save_needs_at_least_one_server_the_bot_is_in(home, discord, handshake, guild_ids):
    _connect_token()

    assert _reason(_call("connectors.discord.save", guild_ids=guild_ids, read_only=True)) == "INVALID_PARAMS"
    assert handshake["configs"] == []


def test_save_writes_the_pinned_read_only_recipe_and_connects_after_the_handshake(home, discord, handshake):
    _connect_token()

    result = _ok("connectors.discord.save", guild_ids=["222", "111"], read_only=True)
    saved = server._methods["mcp.servers.list"](1, {"profile": "work"})

    assert result == {"tools": 2, "read_only": True, "guild_ids": ["111", "222"]}
    assert handshake["configs"] == [("discord", {
        "command": "npx", "args": ["-y", "@pasympa/discord-mcp@2.4.0"],
        "env": {"DISCORD_TOKEN": "${DISCORD_TOKEN}", "DISCORD_MCP_TOOLSETS": "discovery,messages",
                "DISCORD_GUILD_MEMBERS": "false", "DISCORD_MCP_READ_ONLY": "true", "DISCORD_ALLOWED_GUILDS": "111,222"}})]
    assert "${DISCORD_TOKEN}" in (home / "config.yaml").read_text() and TOKEN not in _files(home)
    assert TOKEN not in str(saved)
    row = _row()
    assert (row["status"], row["setup_progress"]["step_id"]) == ("connected", "access")
    assert _ok("connectors.discord.guilds")["allowed"] == ["111", "222"]
    assert handshake["restarts"] == 0


def test_a_failed_handshake_leaves_discord_unconnected(home, discord, handshake):
    _connect_token()
    handshake["tools"] = RuntimeError(f"spawn failed with {TOKEN}")

    response = _call("connectors.discord.save", guild_ids=["111"], read_only=True)

    assert _reason(response) == "CONNECT_FAILED" and TOKEN not in str(response)
    assert _row()["status"] == "not_connected"
    assert "discord" not in {s["name"] for s in _ok("mcp.servers.list")["servers"]}


def test_turning_on_write_restarts_the_live_server_with_the_new_env(home, discord, handshake):
    _connect_token()
    _ok("connectors.discord.save", guild_ids=["111"], read_only=True)

    _ok("connectors.discord.save", guild_ids=["111"], read_only=False)

    assert handshake["configs"][-1][1]["env"]["DISCORD_MCP_READ_ONLY"] == "false"
    assert handshake["restarts"] == 1
    assert _ok("connectors.discord.guilds")["read_only"] is False


def test_a_failed_write_switch_keeps_the_read_only_server(home, discord, handshake):
    _connect_token()
    _ok("connectors.discord.save", guild_ids=["111"], read_only=True)
    handshake["tools"] = []

    assert _reason(_call("connectors.discord.save", guild_ids=["111"], read_only=False)) == "CONNECT_FAILED"
    assert _ok("connectors.discord.guilds")["read_only"] is True and _row()["status"] == "connected"
