"""E2E for the custom MCP connector the Pal app drives: add a user's own server, test it, toggle it
per bot, edit it, remove it.

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
    updated = rpc.mcp("update", name=NAME, config={"url": second.url})
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
