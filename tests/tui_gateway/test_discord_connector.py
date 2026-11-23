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
    return root


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


def test_the_saved_token_lives_only_in_the_root_env_and_fills_the_invite_link(home, discord):
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


def _guilds_error():
    return _call("connectors.discord.guilds")["error"]


GUILDS_FAILURES = [
    ("401", lambda _r: httpx.Response(401, json={"message": "401: Unauthorized", "code": 0}), 4000, "INVALID_TOKEN",
     "Discord didn't accept the saved bot token. Open the Discord developer portal, reset the token and paste it again."),
    ("403-json", lambda _r: httpx.Response(403, json={"message": "Missing Access", "code": 50001}), 4000, "INVALID_TOKEN",
     "Discord refused the saved bot token (error 50001). Open the Discord developer portal, reset the token and paste it again."),
    ("403-html", lambda _r: httpx.Response(403, text="<html>Attention Required! | Cloudflare</html>"), 5034, "CHECK_UNAVAILABLE",
     "Discord blocked the Pal gateway's request before it reached your bot. Try again later."),
    ("429-wait", lambda _r: httpx.Response(429, json={"message": "You are being rate limited.", "retry_after": 41.2}), 5034,
     "CHECK_UNAVAILABLE", "Discord asked Pal to wait 42 seconds. Try again then."),
    ("429-header", lambda _r: httpx.Response(429, headers={"retry-after": "7"}, text="slow down"), 5034, "CHECK_UNAVAILABLE",
     "Discord asked Pal to wait 7 seconds. Try again then."),
    ("429-bare", lambda _r: httpx.Response(429, text="slow down"), 5034, "CHECK_UNAVAILABLE",
     "Discord is limiting the Pal gateway right now. Try again in a minute."),
    ("500", lambda _r: httpx.Response(500, json={"message": "boom"}), 5034, "CHECK_UNAVAILABLE",
     "Discord is having trouble (status 500). Try again in a moment."),
    ("404", lambda _r: httpx.Response(404, json={}), 5034, "CHECK_UNAVAILABLE",
     "Discord answered with an unexpected status (404). Try again."),
    ("html-200", lambda _r: httpx.Response(200, text="<html>maintenance</html>"), 5034, "CHECK_UNAVAILABLE",
     "Discord sent an answer Pal couldn't read. Try again."),
    ("object-200", lambda _r: httpx.Response(200, json={"guilds": []}), 5034, "CHECK_UNAVAILABLE",
     "Discord sent an answer Pal couldn't read. Try again."),
    ("timeout", lambda r: (_ for _ in ()).throw(httpx.ReadTimeout("slow", request=r)), 5034, "CHECK_UNAVAILABLE",
     "The Pal gateway timed out waiting for Discord. Try again."),
    ("offline", lambda r: (_ for _ in ()).throw(httpx.ConnectError("down", request=r)), 5034, "CHECK_UNAVAILABLE",
     "The Pal gateway could not reach Discord. Check its internet connection and try again."),
]


@pytest.fixture
def routed(discord, monkeypatch):
    def handle(request):
        if request.headers.get("authorization") != f"Bot {TOKEN}":
            return httpx.Response(401, json={"message": "401: Unauthorized"})
        if request.url.path == "/api/v10/users/@me":
            return httpx.Response(200, json=discord["me"])
        return state["answer"](request)

    state = {"answer": lambda _r: httpx.Response(200, json=GUILDS)}
    monkeypatch.setattr(checks, "default_transport", httpx.MockTransport(handle))
    monkeypatch.setattr("tui_gateway.discord_connector.time.sleep", lambda _s: None)
    return state


@pytest.mark.parametrize(("answer", "code", "reason", "message"), [c[1:] for c in GUILDS_FAILURES],
                         ids=[c[0] for c in GUILDS_FAILURES])
def test_a_failed_server_list_answers_the_real_reason_and_the_next_step(home, routed, caplog, answer, code, reason, message):
    _connect_token()
    routed["answer"] = answer
    caplog.set_level(logging.DEBUG)

    error = _guilds_error()

    assert (error["code"], error["data"]["reason"], error["message"]) == (code, reason, message)
    assert TOKEN not in caplog.text and TOKEN not in str(error) and "Cloudflare" not in caplog.text


def test_a_short_rate_limit_is_waited_out_once_before_failing(home, routed, monkeypatch):
    _connect_token()
    waits, seen = [], []
    monkeypatch.setattr("tui_gateway.discord_connector.time.sleep", waits.append)

    def answer(_r):
        seen.append(1)
        return httpx.Response(429, json={"retry_after": 0.5}) if len(seen) == 1 else httpx.Response(200, json=GUILDS)

    routed["answer"] = answer

    assert _ok("connectors.discord.guilds")["guilds"] == GUILDS
    assert waits == [0.5] and len(seen) == 2


def test_a_rate_limit_that_persists_is_reported_with_its_wait(home, routed, monkeypatch):
    _connect_token()
    waits = []
    monkeypatch.setattr("tui_gateway.discord_connector.time.sleep", waits.append)
    routed["answer"] = lambda _r: httpx.Response(429, json={"retry_after": 1.2})

    assert _guilds_error()["message"] == "Discord asked Pal to wait 2 seconds. Try again then."
    assert waits == [1.2]


def test_a_long_rate_limit_is_not_slept_through(home, routed, monkeypatch):
    _connect_token()
    waits = []
    monkeypatch.setattr("tui_gateway.discord_connector.time.sleep", waits.append)
    routed["answer"] = lambda _r: httpx.Response(429, json={"retry_after": 30})

    assert _reason({"error": _guilds_error()}) == "CHECK_UNAVAILABLE"
    assert waits == []


def test_an_empty_server_list_is_an_answer_not_a_failure(home, routed):
    _connect_token()
    routed["answer"] = lambda _r: httpx.Response(200, json=[])

    assert _ok("connectors.discord.guilds") == {"guilds": [], "allowed": [], "read_only": True}


def test_a_token_that_discord_stops_accepting_after_the_check_is_refused_with_the_next_step(home, routed):
    _connect_token()
    routed["answer"] = lambda _r: httpx.Response(401, json={"message": "401: Unauthorized"})

    error = _guilds_error()

    assert (error["code"], error["data"]["reason"]) == (4000, "INVALID_TOKEN")
    assert "reset the token and paste it again" in error["message"]


def test_a_pasted_token_that_cannot_be_read_back_is_answered_not_dropped(home, discord):
    response = _call("connectors.discord.token", item="missing-item")

    assert (response["error"]["code"], _reason(response)) == (4000, "CLIENT_UNREADABLE")
    assert response["error"]["message"] == "Couldn't read what you pasted. Paste it again."
