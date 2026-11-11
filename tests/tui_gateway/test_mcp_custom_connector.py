"""E2E for the custom MCP connector the Pal app drives: add a user's own server (bearer token, secret HTTP
headers, OAuth client id), test it, toggle it per bot, edit it, remove it.

Real gateway handlers, a real temp ``HERMES_HOME`` with a named profile ``work``, and a real MCP
server (the installed ``mcp`` SDK) on 127.0.0.1 in a thread. The bearer token is generated per run
and must never reach config.yaml, a list/add/update result, or a ``mcp.servers.test`` error.
"""

from __future__ import annotations

import contextlib
import json
import secrets
import socket
import threading
from pathlib import Path

import hermes_yaml as yaml
import pytest
import uvicorn
from mcp.server import MCPServer

from tests.waiting import wait_until
from tui_gateway import server

PROFILE = "work"
NAME = "notes"


def _build_mcp(*, tools: bool):
    mcp = MCPServer("fake-notes")
    if tools:
        @mcp.tool()
        def echo(text: str) -> str:
            """Echo the text back."""
            return f"echo:{text}"
    return mcp


def _gated(inner, *, token: str | None, status: int | None):
    async def app(scope, receive, send):
        if scope["type"] == "http":
            sent = dict(scope["headers"]).get(b"authorization", b"").decode()
            if status is not None or (token is not None and sent != f"Bearer {token}"):
                body = json.dumps({"error": f"rejected credential {sent}"}).encode()
                await send({"type": "http.response.start", "status": status or 401,
                            "headers": [(b"content-type", b"application/json")]})
                await send({"type": "http.response.body", "body": body})
                return
        await inner(scope, receive, send)

    return app


class FakeMcp:
    def __init__(self, *, token=None, status=None, tools=True, sse=False):
        mcp = _build_mcp(tools=tools)
        inner = mcp.sse_app() if sse else mcp.streamable_http_app()
        self.path = "/sse" if sse else "/mcp"
        app = _gated(inner, token=token, status=status)
        self._uvicorn = uvicorn.Server(uvicorn.Config(
            app, host="127.0.0.1", port=0, log_level="warning", lifespan="on"))
        self._thread = threading.Thread(target=self._uvicorn.run, daemon=True)

    def start(self) -> FakeMcp:
        self._thread.start()
        wait_until(lambda: self._uvicorn.started, what="fake MCP server started")
        return self

    @property
    def url(self) -> str:
        port = self._uvicorn.servers[0].sockets[0].getsockname()[1]
        return f"http://127.0.0.1:{port}{self.path}"

    def stop(self) -> None:
        self._uvicorn.should_exit = True
        self._thread.join(timeout=10)


@pytest.fixture
def fake_mcp():
    started: list[FakeMcp] = []

    def make(**kwargs) -> FakeMcp:
        fake = FakeMcp(**kwargs).start()
        started.append(fake)
        return fake

    yield make
    for fake in started:
        fake.stop()


@pytest.fixture
def token() -> str:
    return secrets.token_urlsafe(24)


@pytest.fixture
def hermes_root(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    (root / "profiles" / PROFILE).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


@pytest.fixture
def work_home(hermes_root) -> Path:
    return hermes_root / "profiles" / PROFILE


class Rpc:
    """Calls a handler and keeps every response so a test can scan them all for a secret."""

    def __init__(self):
        self.responses: list[dict] = []

    def raw(self, method: str, params: dict) -> dict:
        resp = server._methods[method](1, params)
        self.responses.append(resp)
        return resp

    def ok(self, method: str, params: dict) -> dict:
        resp = self.raw(method, params)
        assert "error" not in resp, resp.get("error")
        return resp["result"]

    def mcp(self, verb: str, **params) -> dict:
        return self.ok(f"mcp.servers.{verb}", {"profile": PROFILE, **params})

    def mcp_error(self, verb: str, **params) -> dict:
        resp = self.raw(f"mcp.servers.{verb}", {"profile": PROFILE, **params})
        assert "error" in resp, resp
        return resp["error"]

    def dump(self) -> str:
        return json.dumps(self.responses, default=str)


@pytest.fixture
def rpc() -> Rpc:
    return Rpc()


def _config(home: Path) -> dict:
    path = home / "config.yaml"
    return yaml.safe_load(path.read_text(encoding="utf-8")) if path.is_file() else {}


def _config_text(home: Path) -> str:
    path = home / "config.yaml"
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def _env_text(home: Path) -> str:
    path = home / ".env"
    return path.read_text(encoding="utf-8") if path.is_file() else ""


@contextlib.contextmanager
def _as_bot(home: Path):
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    with server._session_profile_runtime_scope({"profile_home": str(home)}):
        try:
            yield
        finally:
            shutdown_mcp_servers()


def _bot_calls_echo(home: Path, text: str) -> str:
    from tools.mcp_tool_discovery import discover_mcp_tools
    from tools.registry import registry

    with _as_bot(home):
        names = [n for n in discover_mcp_tools() if n.endswith("echo")]
        assert names, "the bot's tool surface has no echo tool"
        return str(registry.dispatch(names[0], {"text": text}))


def _bot_tool_names(home: Path) -> list[str]:
    from tools.mcp_tool_discovery import discover_mcp_tools

    with _as_bot(home):
        return [n for n in discover_mcp_tools() if n.endswith("echo")]


def _assert_secret_free(secret: str, rpc: Rpc, home: Path) -> None:
    assert secret not in rpc.dump()
    assert secret not in _config_text(home)


def test_http_connector_add_test_toggle_call_update_remove(hermes_root, work_home, fake_mcp, rpc, token):
    first = fake_mcp(token=token)
    added = rpc.mcp("add", name=NAME, config={"url": first.url, "transport": "http"}, bearer_token=token)
    assert added["ok"] is True
    assert added["server"]["url"] == first.url
    assert added["server"]["transport"] == "http"
    assert added["server"]["auth"] == "header"
    assert f"MCP_{NAME.upper()}_API_KEY={token}" in _env_text(work_home)
    assert token not in _env_text(hermes_root)

    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is True
    assert [t["name"] for t in probed["tools"]] == ["echo"]
    assert probed.get("reason") is None

    configured = rpc.ok("profiles.configure", {"name": PROFILE, "enabled_mcp_servers": []})
    assert configured["applied"]["mcp_servers"] is True
    assert _bot_tool_names(work_home) == []
    described = rpc.ok("profiles.describe", {"name": PROFILE})
    assert {s["name"]: s["enabled"] for s in described["mcp_servers"]}[NAME] is False

    rpc.ok("profiles.configure", {"name": PROFILE, "enabled_mcp_servers": [NAME]})
    described = rpc.ok("profiles.describe", {"name": PROFILE})
    assert {s["name"]: s["enabled"] for s in described["mcp_servers"]}[NAME] is True
    assert "echo:hello" in _bot_calls_echo(work_home, "hello")

    second = fake_mcp(token=token)
    updated = rpc.mcp("update", name=NAME, config={"url": second.url}, bearer_token=token)
    assert updated["ok"] is True and updated["name"] == NAME
    assert updated["server"]["url"] == second.url
    assert updated["server"]["auth"] == "header"
    assert _config(work_home)["mcp_servers"][NAME]["enabled"] is True
    assert rpc.mcp("test", name=NAME)["ok"] is True
    first.stop()
    assert "echo:again" in _bot_calls_echo(work_home, "again")

    assert rpc.mcp("remove", name=NAME) == {"ok": True, "removed": True}
    assert rpc.mcp("list")["servers"] == []
    assert NAME not in (_config(work_home).get("mcp_servers") or {})
    _assert_secret_free(token, rpc, work_home)


def test_sse_connector_is_probed_and_reported_as_sse(work_home, fake_mcp, rpc, token):
    sse = fake_mcp(token=token, sse=True)
    added = rpc.mcp("add", name=NAME, config={"url": sse.url, "transport": "sse"}, bearer_token=token)
    assert added["server"]["transport"] == "sse"
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is True and [t["name"] for t in probed["tools"]] == ["echo"]
    assert rpc.mcp("list")["servers"][0]["transport"] == "sse"
    _assert_secret_free(token, rpc, work_home)


def test_unreachable_server_reports_reason_unreachable(work_home, rpc):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    rpc.mcp("add", name=NAME, config={"url": f"http://127.0.0.1:{port}/mcp"})
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["tools"] == []
    assert probed["reason"] == "unreachable"
    assert probed["error"]


@pytest.mark.parametrize("sent", ["wrong", None], ids=["wrong-token", "no-token"])
def test_refused_credential_reports_reason_auth_refused(work_home, fake_mcp, rpc, token, sent):
    refusing = fake_mcp(token=token)
    rpc.mcp("add", name=NAME, config={"url": refusing.url}, **({"bearer_token": sent} if sent else {}))
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["tools"] == []
    assert probed["reason"] == "auth_refused"


def test_server_error_reports_reason_server_error(work_home, fake_mcp, rpc):
    broken = fake_mcp(status=500)
    rpc.mcp("add", name=NAME, config={"url": broken.url})
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["reason"] == "server_error"


def test_server_without_tools_is_ok_with_an_empty_list(work_home, fake_mcp, rpc):
    empty = fake_mcp(tools=False)
    rpc.mcp("add", name=NAME, config={"url": empty.url})
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is True and probed["tools"] == []
    assert probed.get("reason") is None and probed.get("error") is None


def test_test_error_never_contains_the_bearer_token_even_when_the_server_echoes_it(
        work_home, fake_mcp, rpc, token):
    echoing = fake_mcp(token=secrets.token_urlsafe(24))
    rpc.mcp("add", name=NAME, config={"url": echoing.url}, bearer_token=token)
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["reason"] == "auth_refused"
    assert "rejected credential" in probed["error"]
    assert token not in probed["error"]
    assert f"Bearer {token}" not in probed["error"]
    assert token in _env_text(work_home)
    _assert_secret_free(token, rpc, work_home)


@pytest.mark.parametrize("url", ["ftp://example.com/mcp", "javascript:alert(1)", "http://", "http://:8080/mcp",
                                 "example.com/mcp", "file:///etc/passwd", "   "])
def test_add_rejects_an_invalid_url(work_home, rpc, url):
    error = rpc.mcp_error("add", name=NAME, config={"url": url})
    assert error["code"] == 4063 and error["message"] == "invalid url"
    assert rpc.mcp("list")["servers"] == []


@pytest.mark.parametrize("transport", ["websocket", "stdio", "streamable-http", "SSE", 5])
def test_add_rejects_an_unsupported_transport(work_home, rpc, transport):
    error = rpc.mcp_error("add", name=NAME, config={"url": "https://example.com/mcp", "transport": transport})
    assert error["code"] == 4063 and error["message"] == "unsupported transport"
    assert rpc.mcp("list")["servers"] == []


def test_add_keeps_accepting_the_existing_shapes(work_home, rpc):
    rpc.mcp("add", name="plain", config={"url": "https://example.com/mcp"})
    rpc.mcp("add", name="explicit", config={"url": "http://127.0.0.1:9/mcp", "transport": "http"})
    rpc.mcp("add", name="local", config={"command": "python", "args": ["-m", "server"]})
    assert {s["name"] for s in rpc.mcp("list")["servers"]} == {"plain", "explicit", "local"}


def test_list_never_echoes_header_values(work_home, rpc):
    secret = secrets.token_urlsafe(18)
    rpc.mcp("add", name=NAME, config={
        "url": "https://example.com/mcp",
        "headers": {"X-Api-Key": secret, "Authorization": f"Bearer {secret}"},
        "env": {"SOME_ENV": secret}})
    listed = rpc.mcp("list")["servers"][0]
    assert listed["auth"] == "header"
    assert secret not in rpc.dump()


def test_update_unknown_server_is_4064(work_home, rpc):
    error = rpc.mcp_error("update", name="ghost", config={"url": "https://example.com/mcp"})
    assert error["code"] == 4064


def test_update_plugin_owned_server_is_refused(work_home, rpc, monkeypatch):
    from tui_gateway import mcp_rpc_helpers

    real = mcp_rpc_helpers.server_configs_with_sources
    monkeypatch.setattr(mcp_rpc_helpers, "server_configs_with_sources", lambda cfg: (
        {**real(cfg)[0], "bundled": {"url": "https://example.com/mcp"}}, {"bundled": "some-plugin"}))
    error = rpc.mcp_error("update", name="bundled", config={"url": "https://example.com/other"})
    assert error["code"] == 4090 and "some-plugin" in error["message"]


def test_update_validates_like_add(work_home, rpc):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/mcp"})
    assert rpc.mcp_error("update", name=NAME, config={"url": "ftp://x"})["message"] == "invalid url"
    assert rpc.mcp_error("update", name=NAME, config={"transport": "grpc"})["message"] == "unsupported transport"
    assert _config(work_home)["mcp_servers"][NAME]["url"] == "https://example.com/mcp"


def test_update_changes_transport_and_keeps_unrelated_fields(work_home, rpc):
    rpc.mcp("add", name=NAME, config={
        "url": "https://example.com/mcp", "enabled": False, "tools": {"include": ["echo"]},
        "headers": {"X-Team": "blue"}})
    updated = rpc.mcp("update", name=NAME, config={"transport": "sse"})
    assert updated["server"]["transport"] == "sse"
    saved = _config(work_home)["mcp_servers"][NAME]
    assert saved["url"] == "https://example.com/mcp" and saved["transport"] == "sse"
    assert saved["enabled"] is False and saved["tools"] == {"include": ["echo"]}
    assert saved["headers"] == {"X-Team": "blue"}


def test_update_auth_bearer_then_none_manages_header_and_env(work_home, rpc, token):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/mcp", "headers": {"X-Team": "blue"}})
    var = f"MCP_{NAME.upper()}_API_KEY"

    bearer = rpc.mcp("update", name=NAME, auth="bearer", bearer_token=token)
    assert bearer["server"]["auth"] == "header"
    saved = _config(work_home)["mcp_servers"][NAME]
    assert saved["headers"] == {"X-Team": "blue", "Authorization": f"Bearer ${{{var}}}"}
    assert f"{var}={token}" in _env_text(work_home)

    swapped = secrets.token_urlsafe(24)
    rpc.mcp("update", name=NAME, bearer_token=f"Bearer {swapped}")
    assert f"{var}={swapped}" in _env_text(work_home) and token not in _env_text(work_home)

    cleared = rpc.mcp("update", name=NAME, auth="none")
    assert cleared["server"]["auth"] is None
    saved = _config(work_home)["mcp_servers"][NAME]
    assert saved["headers"] == {"X-Team": "blue"} and "auth" not in saved
    assert var not in _env_text(work_home)
    for secret in (token, swapped):
        _assert_secret_free(secret, rpc, work_home)
        assert secret not in _env_text(work_home)


def test_update_auth_none_drops_an_empty_headers_block(work_home, rpc, token):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/mcp"}, bearer_token=token)
    rpc.mcp("update", name=NAME, auth="none")
    assert "headers" not in _config(work_home)["mcp_servers"][NAME]


def test_update_auth_oauth_replaces_the_bearer_header(work_home, rpc, token):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/mcp"}, bearer_token=token)
    updated = rpc.mcp("update", name=NAME, auth="oauth")
    assert updated["server"]["auth"] == "oauth"
    saved = _config(work_home)["mcp_servers"][NAME]
    assert saved["auth"] == "oauth" and "headers" not in saved
    assert f"MCP_{NAME.upper()}_API_KEY" not in _env_text(work_home)


@pytest.mark.parametrize("params", [
    {"auth": "bearer"},
    {"auth": "none", "bearer_token": "x-token"},
    {"auth": "oauth", "bearer_token": "x-token"},
    {"auth": "bearer", "bearer_token": "Bearer "},
    {"auth": "basic"},
], ids=["bearer-without-token", "none-with-token", "oauth-with-token", "empty-token", "unknown-auth"])
def test_update_rejects_inconsistent_auth_arguments(work_home, rpc, params):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/mcp"})
    before = _config_text(work_home)
    error = rpc.raw("mcp.servers.update", {"profile": PROFILE, "name": NAME, **params})["error"]
    assert error["code"] == 4063
    assert _config_text(work_home) == before


def test_update_refuses_a_local_command_server(work_home, rpc):
    rpc.mcp("add", name="local", config={"command": "python", "args": ["-m", "server"]})
    error = rpc.mcp_error("update", name="local", config={"url": "https://example.com/mcp"})
    assert error["code"] == 4063
    assert "url" not in _config(work_home)["mcp_servers"]["local"]


def test_update_lands_in_the_named_profile_only(hermes_root, work_home, rpc):
    rpc.mcp("add", name=NAME, config={"url": "https://example.com/one"})
    rpc.ok("mcp.servers.add", {"name": NAME, "config": {"url": "https://example.com/launch"}})
    rpc.mcp("update", name=NAME, config={"url": "https://example.com/two"})
    assert _config(work_home)["mcp_servers"][NAME]["url"] == "https://example.com/two"
    assert _config(hermes_root)["mcp_servers"][NAME]["url"] == "https://example.com/launch"


API_VAR = f"MCP_{NAME.upper()}_HDR_X_API_KEY"
TEAM_VAR = f"MCP_{NAME.upper()}_HDR_X_TEAM_TOKEN"
AUTH_VAR = f"MCP_{NAME.upper()}_API_KEY"
URL = "https://example.com/mcp"


def _requiring(inner, required: dict[str, str], challenge: str | None, echo: str | None):
    async def app(scope, receive, send):
        if scope["type"] == "http":
            sent = {k.decode().lower(): v.decode() for k, v in scope["headers"]}
            if any(sent.get(k.lower()) != v for k, v in required.items()):
                body = json.dumps({"error": f"rejected {sent.get(echo.lower(), '') if echo else ''}"}).encode()
                headers = [(b"content-type", b"application/json")]
                if challenge:
                    headers.append((b"www-authenticate", challenge.encode()))
                await send({"type": "http.response.start", "status": 401, "headers": headers})
                await send({"type": "http.response.body", "body": body})
                return
        await inner(scope, receive, send)

    return app


class HeaderMcp:
    def __init__(self, required: dict[str, str], *, challenge: str | None = None, echo: str | None = None):
        app = _requiring(_build_mcp(tools=True).streamable_http_app(), required, challenge, echo)
        self._uvicorn = uvicorn.Server(uvicorn.Config(
            app, host="127.0.0.1", port=0, log_level="warning", lifespan="on"))
        self._thread = threading.Thread(target=self._uvicorn.run, daemon=True)
        self._thread.start()
        wait_until(lambda: self._uvicorn.started, what="header MCP server started")

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self._uvicorn.servers[0].sockets[0].getsockname()[1]}/mcp"

    def stop(self) -> None:
        self._uvicorn.should_exit = True
        self._thread.join(timeout=10)


@pytest.fixture
def header_mcp():
    started: list[HeaderMcp] = []

    def make(required, **kwargs) -> HeaderMcp:
        started.append(HeaderMcp(required, **kwargs))
        return started[-1]

    yield make
    for server in started:
        server.stop()


def _secret() -> str:
    return secrets.token_urlsafe(18)


def _saved(home) -> dict:
    return _config(home)["mcp_servers"][NAME]


def _env_vars(home) -> set[str]:
    return {line.split("=", 1)[0] for line in _env_text(home).splitlines() if line.startswith("MCP_")}


def _assert_no_values(secret_values, rpc: Rpc, home) -> None:
    for value in secret_values:
        _assert_secret_free(value, rpc, home)


def test_headers_connector_add_test_call_update_remove_leaves_no_orphaned_secret(
        hermes_root, work_home, header_mcp, rpc):
    api, bearer, team = _secret(), _secret(), _secret()
    mcp = header_mcp({"x-api-key": api, "authorization": f"Bearer {bearer}", "x-team-token": team})
    added = rpc.mcp("add", name=NAME, config={"url": mcp.url, "transport": "http"},
                    headers={"X-Api-Key": api, "Authorization": f"Bearer {bearer}", "X-Team-Token": team})
    assert added["server"]["headers"] == ["X-Api-Key", "Authorization", "X-Team-Token"]
    assert added["server"]["auth"] == "header"

    saved = _saved(work_home)
    assert saved["headers"] == {"X-Api-Key": f"${{{API_VAR}}}", "Authorization": f"Bearer ${{{AUTH_VAR}}}",
                                "X-Team-Token": f"${{{TEAM_VAR}}}"}
    env = _env_text(work_home)
    assert f"{API_VAR}={api}" in env and f"{AUTH_VAR}={bearer}" in env and f"{TEAM_VAR}={team}" in env
    for value in (api, bearer, team):
        assert value not in _env_text(hermes_root)

    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is True and [t["name"] for t in probed["tools"]] == ["echo"]
    rpc.ok("profiles.configure", {"name": PROFILE, "enabled_mcp_servers": [NAME]})
    assert "echo:hi" in _bot_calls_echo(work_home, "hi")

    listed = rpc.mcp("list")["servers"][0]
    assert listed["headers"] == ["X-Api-Key", "Authorization", "X-Team-Token"] and listed["client_id"] is None

    rotated = _secret()
    mcp.stop()
    mcp = header_mcp({"x-api-key": rotated, "authorization": f"Bearer {bearer}"})
    updated = rpc.mcp("update", name=NAME, config={"url": mcp.url},
                      headers={"X-Api-Key": rotated, "Authorization": f"Bearer {bearer}"})
    assert updated["server"]["headers"] == ["X-Api-Key", "Authorization"]
    saved = _saved(work_home)
    assert saved["headers"] == {"X-Api-Key": f"${{{API_VAR}}}", "Authorization": f"Bearer ${{{AUTH_VAR}}}"}
    env = _env_text(work_home)
    assert f"{API_VAR}={rotated}" in env and f"{AUTH_VAR}={bearer}" in env
    assert TEAM_VAR not in env and api not in env and team not in env
    assert rpc.mcp("test", name=NAME)["ok"] is True

    assert rpc.mcp("remove", name=NAME) == {"ok": True, "removed": True}
    assert _env_vars(work_home) == set()
    assert NAME not in (_config(work_home).get("mcp_servers") or {})
    _assert_no_values([api, bearer, team, rotated], rpc, work_home)
    assert not any(value in _env_text(work_home) for value in (api, bearer, team, rotated))


def test_an_authorization_row_is_the_same_state_as_the_bearer_token_path(work_home, rpc):
    token = _secret()
    rpc.mcp("add", name="via-row", config={"url": URL}, headers={"Authorization": f"Bearer {token}"})
    via_row = (_config(work_home)["mcp_servers"]["via-row"]["headers"], _env_text(work_home))
    rpc.mcp("remove", name="via-row")
    rpc.mcp("add", name="via-row", config={"url": URL}, bearer_token=token)
    assert via_row == (_config(work_home)["mcp_servers"]["via-row"]["headers"], _env_text(work_home))
    assert via_row[0] == {"Authorization": "Bearer ${MCP_VIA_ROW_API_KEY}"}


def test_a_header_without_a_bearer_prefix_is_stored_whole(work_home, rpc):
    basic = f"Basic {_secret()}"
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"Authorization": basic, "X-Api-Key": _secret()})
    assert _saved(work_home)["headers"]["Authorization"] == f"${{{AUTH_VAR}}}"
    assert basic in _env_text(work_home)


@pytest.mark.parametrize("headers", [
    {"Bad Name": "value-123"}, {"": "value-123"}, {"X-Ok": "line\r\nInjected: 1"}, {"X-Ok": "tab\x00nul"},
    {"X-Ok": ""}, {"X-Ok": "   "}, {"X-Ok": "x" * 5000}, {"x-ok": "value-123", "X-OK": "value-456"},
    {"X-Ok": "${OPENAI_API_KEY}"}, {"Host": "evil.example"}, {"Content-Length": "1"},
    {"X-Ok": None}, {"Authorization": "Bearer"}, {"X-A": "aaaaaa-1", "X_A": "aaaaaa-2"},
    {f"X-{i}": "value-123" for i in range(21)},
], ids=["space-in-name", "empty-name", "crlf", "nul", "empty-value", "blank-value", "too-long", "case-dup",
        "env-reference", "host", "content-length", "null-on-add", "bare-bearer", "var-collision", "too-many"])
def test_add_rejects_invalid_headers_before_any_write(work_home, rpc, headers):
    error = rpc.mcp_error("add", name=NAME, config={"url": URL}, headers=headers)
    assert error["code"] == 4063
    assert rpc.mcp("list")["servers"] == []
    assert _env_vars(work_home) == set() and "mcp_servers" not in _config(work_home)


def test_add_rejects_a_header_that_repeats_one_in_config_and_a_bad_client_id(work_home, rpc):
    clash = rpc.mcp_error("add", name=NAME, config={"url": URL, "headers": {"x-api-key": "literal"}},
                          headers={"X-Api-Key": _secret()})
    assert clash["code"] == 4063
    for client_id in ("has space", "x" * 600, "new\nline"):
        assert rpc.mcp_error("add", name=NAME, config={"url": URL}, client_id=client_id)["code"] == 4063
    assert rpc.mcp("list")["servers"] == []


def test_header_variables_cannot_collide_across_servers(work_home, rpc):
    first = _secret()
    rpc.mcp("add", name="a-b", config={"url": URL}, headers={"Authorization": f"Bearer {first}"})
    error = rpc.mcp_error("add", name="a_b", config={"url": URL}, headers={"Authorization": f"Bearer {_secret()}"})
    assert error["code"] == 4063
    assert f"MCP_A_B_API_KEY={first}" in _env_text(work_home)
    assert [s["name"] for s in rpc.mcp("list")["servers"]] == ["a-b"]


def test_update_replaces_keeps_and_removes_header_keys_and_their_env_values(work_home, rpc):
    api, team, bearer = _secret(), _secret(), _secret()
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"X-Api-Key": api, "X-Team-Token": team})

    kept = rpc.mcp("update", name=NAME, headers={"X-Api-Key": None, "X-Team-Token": team + "x"})
    assert kept["server"]["headers"] == ["X-Api-Key", "X-Team-Token"]
    env = _env_text(work_home)
    assert f"{API_VAR}={api}" in env and f"{TEAM_VAR}={team}x" in env

    replaced = _secret()
    rpc.mcp("update", name=NAME, headers={"X-Api-Key": replaced, "Authorization": f"Bearer {bearer}"})
    env = _env_text(work_home)
    assert f"{API_VAR}={replaced}" in env and f"{AUTH_VAR}={bearer}" in env and TEAM_VAR not in env
    assert set(_saved(work_home)["headers"]) == {"X-Api-Key", "Authorization"}

    emptied = rpc.mcp("update", name=NAME, headers={})
    assert emptied["server"]["headers"] == [] and emptied["server"]["auth"] is None
    assert "headers" not in _saved(work_home) and _env_vars(work_home) == set()
    _assert_no_values([api, team, replaced, bearer], rpc, work_home)


def test_update_without_headers_param_leaves_headers_and_env_alone(work_home, rpc):
    api = _secret()
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"X-Api-Key": api})
    rpc.mcp("update", name=NAME, config={"transport": "sse"})
    assert _saved(work_home)["headers"] == {"X-Api-Key": f"${{{API_VAR}}}"}
    assert f"{API_VAR}={api}" in _env_text(work_home)


def test_update_refuses_bad_headers_and_keeps_config_and_env_untouched(work_home, rpc):
    api = _secret()
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"X-Api-Key": api})
    config_before, env_before = _config_text(work_home), _env_text(work_home)
    attempts = (
        {"headers": {"X-New": None}},
        {"headers": {"X-Api-Key": "bad\r\nvalue"}},
        {"headers": {"X-Api-Key": _secret()}, "bearer_token": _secret()},
        {"headers": {"X-Api-Key": _secret()}, "auth": "none"},
        {"headers": {"X-Api-Key": _secret(), "x-api-key": _secret()}},
        {"client_id": "has space"},
    )
    for params in attempts:
        assert rpc.mcp_error("update", name=NAME, **params)["code"] == 4063, params
    assert _config_text(work_home) == config_before and _env_text(work_home) == env_before


def test_legacy_bearer_update_and_auth_none_still_manage_the_token_var(work_home, rpc):
    token = _secret()
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"X-Api-Key": _secret()})
    rpc.mcp("update", name=NAME, auth="bearer", bearer_token=token)
    assert _saved(work_home)["headers"]["Authorization"] == f"Bearer ${{{AUTH_VAR}}}"
    assert f"{AUTH_VAR}={token}" in _env_text(work_home) and API_VAR in _env_text(work_home)
    rpc.mcp("update", name=NAME, auth="none")
    assert AUTH_VAR not in _env_text(work_home) and API_VAR in _env_text(work_home)


def test_changing_the_origin_requires_every_secret_header_to_be_re_sent(work_home, rpc):
    api, team = _secret(), _secret()
    rpc.mcp("add", name=NAME, config={"url": "https://good.example/mcp"},
            headers={"X-Api-Key": api, "X-Team-Token": team})
    moved = {"url": "https://other.example/mcp"}

    for params in ({"headers": {"X-Api-Key": api, "X-Team-Token": None}}, {"headers": {"X-Api-Key": None}},
                   {}, {"headers": {"X-Api-Key": None, "X-Team-Token": team}}):
        error = rpc.mcp_error("update", name=NAME, config=moved, **params)
        assert error["code"] == 4063 and error["message"] == "re-enter headers for the new address", params
    assert _saved(work_home)["url"] == "https://good.example/mcp"
    assert f"{API_VAR}={api}" in _env_text(work_home) and f"{TEAM_VAR}={team}" in _env_text(work_home)

    new_api, new_team = _secret(), _secret()
    rpc.mcp("update", name=NAME, config=moved, headers={"X-Api-Key": new_api, "X-Team-Token": new_team})
    assert _saved(work_home)["url"] == "https://other.example/mcp"
    env = _env_text(work_home)
    assert f"{API_VAR}={new_api}" in env and f"{TEAM_VAR}={new_team}" in env and api not in env
    same_origin = rpc.mcp("update", name=NAME, config={"url": "https://other.example/other/path"},
                          headers={"X-Api-Key": None, "X-Team-Token": None})
    assert same_origin["server"]["url"] == "https://other.example/other/path"


def test_changing_the_origin_is_refused_for_a_bearer_token_unless_it_is_re_sent(work_home, rpc):
    token = _secret()
    rpc.mcp("add", name=NAME, config={"url": "https://good.example/mcp"}, bearer_token=token)
    error = rpc.mcp_error("update", name=NAME, config={"url": "https://other.example/mcp"})
    assert error["code"] == 4063 and error["message"] == "re-enter headers for the new address"
    fresh = _secret()
    rpc.mcp("update", name=NAME, config={"url": "https://other.example/mcp"}, bearer_token=fresh)
    assert f"{AUTH_VAR}={fresh}" in _env_text(work_home)
    rpc.mcp("update", name=NAME, config={"url": "https://third.example/mcp"}, auth="none")
    assert "headers" not in _saved(work_home)


def test_changing_the_origin_is_free_without_secret_headers(work_home, rpc):
    rpc.mcp("add", name=NAME, config={"url": "https://good.example/mcp", "headers": {"X-Team": "blue"}})
    moved = rpc.mcp("update", name=NAME, config={"url": "https://other.example/mcp"})
    assert moved["server"]["url"] == "https://other.example/mcp"


def test_test_error_never_contains_a_header_value_the_server_echoes(work_home, header_mcp, rpc):
    right, wrong = _secret(), _secret()
    server = header_mcp({"x-api-key": right}, echo="x-api-key")
    rpc.mcp("add", name=NAME, config={"url": server.url}, headers={"X-Api-Key": wrong})
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["reason"] == "auth_refused"
    assert "rejected" in probed["error"] and wrong not in probed["error"]
    assert f"{API_VAR}={wrong}" in _env_text(work_home)
    _assert_no_values([wrong, right], rpc, work_home)


def test_a_401_with_a_bearer_challenge_asks_the_app_to_start_oauth(work_home, header_mcp, rpc):
    server = header_mcp({"x-never": "sent"}, challenge='Bearer resource_metadata="https://auth.example/meta"')
    rpc.mcp("add", name=NAME, config={"url": server.url}, headers={"X-Team": "not-secret-blue"})
    probed = rpc.mcp("test", name=NAME)
    assert probed["ok"] is False and probed["reason"] == "auth_refused" and probed["oauth_needed"] is True


def test_a_401_without_any_header_configured_asks_the_app_to_start_oauth(work_home, header_mcp, rpc):
    server = header_mcp({"x-never": "sent"})
    rpc.mcp("add", name=NAME, config={"url": server.url})
    probed = rpc.mcp("test", name=NAME)
    assert probed["reason"] == "auth_refused" and probed["oauth_needed"] is True


def test_a_refused_credential_does_not_offer_oauth(work_home, header_mcp, rpc):
    server = header_mcp({"x-api-key": _secret()}, challenge='Bearer error="invalid_token"')
    rpc.mcp("add", name=NAME, config={"url": server.url}, headers={"Authorization": f"Bearer {_secret()}"})
    wrong_authorization = rpc.mcp("test", name=NAME)
    assert wrong_authorization["reason"] == "auth_refused" and wrong_authorization["oauth_needed"] is False
    rpc.mcp("remove", name=NAME)

    plain = header_mcp({"x-api-key": _secret()})
    rpc.mcp("add", name=NAME, config={"url": plain.url}, headers={"X-Api-Key": _secret()})
    wrong_key = rpc.mcp("test", name=NAME)
    assert wrong_key["reason"] == "auth_refused" and wrong_key["oauth_needed"] is False


def test_client_id_is_stored_as_non_secret_oauth_config_and_listed(work_home, rpc):
    added = rpc.mcp("add", name=NAME, config={"url": URL}, client_id="pal-client-1")
    assert added["server"]["client_id"] == "pal-client-1"
    assert _saved(work_home)["oauth"] == {"client_id": "pal-client-1"}

    changed = rpc.mcp("update", name=NAME, client_id="pal-client-2")
    assert changed["server"]["client_id"] == "pal-client-2"
    untouched = rpc.mcp("update", name=NAME, config={"transport": "sse"})
    assert untouched["server"]["client_id"] == "pal-client-2"
    cleared = rpc.mcp("update", name=NAME, client_id="")
    assert cleared["server"]["client_id"] is None and "oauth" not in _saved(work_home)


def test_oauth_start_uses_the_client_id_and_persists_it_with_the_authorization(work_home, rpc, monkeypatch):
    from tui_gateway import mcp_oauth_sessions

    seen: list[dict] = []
    monkeypatch.setattr(mcp_oauth_sessions, "start_flow", lambda home, name, cfg, **kw: (
        seen.append(cfg) or {"session_id": "flow", "auth_url": "https://auth.example/authorize", "flow": "pkce"}))
    rpc.mcp("add", name=NAME, config={"url": URL})
    rpc.mcp("oauth.start", name=NAME, client_redirect_uri="http://127.0.0.1:5555/callback",
            client_id="pal-client-9")
    assert seen[0]["oauth"] == {"client_id": "pal-client-9"} and seen[0]["auth"] == "oauth"
    assert rpc.mcp_error("oauth.start", name=NAME, client_id="bad id")["code"] == 4063
    rpc.mcp("oauth.start", name=NAME)
    assert "oauth" not in seen[-1]


def test_summary_lists_header_names_but_never_values_or_variable_values(work_home, rpc):
    api = _secret()
    rpc.mcp("add", name=NAME, config={"url": URL, "headers": {"X-Team": "literal-blue"}}, headers={"X-Api-Key": api})
    listed = rpc.mcp("list")["servers"][0]
    assert listed["headers"] == ["X-Team", "X-Api-Key"]
    assert api not in rpc.dump()
    assert "literal-blue" not in json.dumps(listed)


def test_headers_land_in_the_named_profile_env_only(hermes_root, work_home, rpc):
    api = _secret()
    rpc.mcp("add", name=NAME, config={"url": URL}, headers={"X-Api-Key": api})
    assert f"{API_VAR}={api}" in _env_text(work_home)
    assert API_VAR not in _env_text(hermes_root) and api not in _config_text(hermes_root)
