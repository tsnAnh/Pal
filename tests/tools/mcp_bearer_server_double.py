from __future__ import annotations

import asyncio
import json
import socket
import threading
from dataclasses import dataclass, field
from enum import Enum

import uvicorn
from mcp.server import MCPServer
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from mcp.types import ToolAnnotations

from tests.waiting import wait_until

READ_ONLY = ToolAnnotations(readOnlyHint=True)
TOOL_NAMES = ("whoami", "list_projects", "create_item")


class Protection(str, Enum):
    NONE = "none"
    STATIC_KEY = "static_key"
    OAUTH = "oauth"


@dataclass(frozen=True)
class ToolCall:
    tool: str
    arguments: dict
    bearer: str | None
    account: str


@dataclass
class Traffic:
    tool_calls: list[ToolCall] = field(default_factory=list)
    statuses: list[tuple[str, int, bool]] = field(default_factory=list)

    def calls(self, tool: str) -> list[ToolCall]:
        return [c for c in self.tool_calls if c.tool == tool]

    def rejected(self) -> int:
        return sum(1 for _path, status, _bearer in self.statuses if status == 401)


class _Verifier:
    def __init__(self, double: McpServerDouble):
        self.double = double

    async def verify_token(self, token: str) -> AccessToken | None:
        if self.double.protection is Protection.STATIC_KEY:
            if token != self.double.api_key:
                return None
            return AccessToken(token=token, client_id="api-key", scopes=[], subject="api-key")
        grant = self.double.authorization_server.verify(token)
        if grant is None:
            return None
        return AccessToken(token=token, client_id=grant.client_id, scopes=[], subject=grant.account)


class _Recorder:
    def __init__(self, app, traffic: Traffic):
        self.app, self.traffic = app, traffic

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        bearer = any(k == b"authorization" for k, _ in scope["headers"])

        async def recording_send(message):
            if message["type"] == "http.response.start":
                self.traffic.statuses.append((scope["path"], message["status"], bearer))
            await send(message)

        await self.app(scope, receive, recording_send)


class McpServerDouble:
    def __init__(self, *, protection: Protection = Protection.NONE, authorization_server=None, api_key: str = "pal-api-key"):
        if protection is Protection.OAUTH and authorization_server is None:
            raise ValueError("an OAuth-protected MCP server needs an authorization server")
        self.protection = protection
        self.authorization_server = authorization_server
        self.api_key = api_key
        self.traffic = Traffic()
        self._listener = socket.socket()
        self._listener.bind(("127.0.0.1", 0))
        self.port = self._listener.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.mcp_url = f"{self.base}/mcp"
        self._uvicorn: uvicorn.Server | None = None
        self._thread: threading.Thread | None = None

    def _server(self) -> MCPServer:
        kwargs = {}
        if self.protection is not Protection.NONE:
            issuer = self.authorization_server.base if self.authorization_server else self.base
            kwargs = {"token_verifier": _Verifier(self),
                      "auth": AuthSettings(issuer_url=issuer, resource_server_url=self.mcp_url,
                                         validate_token_resource=False)}
        server = MCPServer("pal-auth-double", **kwargs)
        double = self

        def serve(tool: str, arguments: dict) -> str:
            token = get_access_token()
            account = token.subject if token else "anonymous"
            double.traffic.tool_calls.append(ToolCall(tool, dict(arguments), token.token if token else None, account))
            return json.dumps({"account": account, "tool": tool, "arguments": arguments})

        @server.tool(annotations=READ_ONLY)
        def whoami() -> str:
            return serve("whoami", {})

        @server.tool(annotations=READ_ONLY)
        def list_projects(limit: int = 10) -> str:
            return serve("list_projects", {"limit": limit})

        @server.tool()
        def create_item(title: str = "") -> str:
            return serve("create_item", {"title": title})

        return server

    def start(self) -> McpServerDouble:
        app = _Recorder(self._server().streamable_http_app(host="127.0.0.1"), self.traffic)
        self._uvicorn = uvicorn.Server(uvicorn.Config(app, log_level="warning", lifespan="on", timeout_graceful_shutdown=1))
        server = self._uvicorn
        self._thread = threading.Thread(
            target=lambda: asyncio.run(server.serve(sockets=[self._listener])), daemon=True, name="mcp-server-double")
        self._thread.start()
        wait_until(lambda: server.started, what="MCP server double started")
        return self

    def stop(self) -> None:
        if self._uvicorn is not None:
            self._uvicorn.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout=10)
        self._listener.close()

    def __enter__(self) -> McpServerDouble:
        return self.start()

    def __exit__(self, *_exc) -> None:
        self.stop()
