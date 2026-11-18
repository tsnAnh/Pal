from __future__ import annotations

import base64
import hashlib
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

TOOLS = [
    {"name": "list_projects", "description": "List projects.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "start_thread", "description": "Start a thread.", "inputSchema": {"type": "object", "properties": {}}},
]


def accepts_everything(uri: str) -> bool:
    return True


def accepts_loopback_only(uri: str) -> bool:
    return uri.startswith("http://127.0.0.1:")


def accepts_nothing(uri: str) -> bool:
    return False


T3_REFUSAL = "Redirect URIs must be https, or http on localhost, 127.0.0.1 or [::1]"


def accepts_what_t3_accepts(uri: str) -> bool:
    return uri.startswith(("https://", "http://localhost", "http://127.0.0.1", "http://[::1]"))


class T3CodeDouble:
    """A plain-http stand-in that answers like T3 Code's MCP endpoint and OAuth server."""

    def __init__(self, *, accepts=accepts_everything, mcp_behaviour="mcp"):
        self.accepts = accepts
        self.refusal = None
        self.mcp_behaviour = mcp_behaviour
        self.registrations: list[dict] = []
        self.requests: list[tuple[str, str]] = []
        self.token_requests: list[dict] = []
        self.codes: dict[str, str] = {}
        self.tokens: set[str] = set()
        double = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_GET(self):
                double._route(self, "GET")

            def do_POST(self):
                double._route(self, "POST")

            def do_DELETE(self):
                double._route(self, "DELETE")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.mcp_url = f"{self.base}/mcp"
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)

    def start(self) -> T3CodeDouble:
        self._thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def __enter__(self) -> T3CodeDouble:
        return self.start()

    def __exit__(self, *_exc) -> None:
        self.stop()

    def _send(self, h, status, body=None, headers=None, content_type="application/json"):
        raw = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        h.send_response(status)
        if raw:
            h.send_header("Content-Type", content_type)
        h.send_header("Content-Length", str(len(raw)))
        for key, value in (headers or {}).items():
            h.send_header(key, value)
        h.end_headers()
        h.wfile.write(raw)

    def _body(self, h) -> bytes:
        return h.rfile.read(int(h.headers.get("Content-Length") or 0))

    def _route(self, h, method: str) -> None:
        path = urlsplit(h.path).path
        self.requests.append((method, path))
        if path == "/mcp":
            return self._mcp(h, method)
        if path == "/.well-known/oauth-protected-resource/mcp":
            return self._send(h, 200, {
                "resource": self.mcp_url, "authorization_servers": [self.base],
                "scopes_supported": ["orchestration:read", "orchestration:operate"]})
        if path == "/.well-known/oauth-authorization-server":
            return self._send(h, 200, {
                "issuer": self.base, "authorization_endpoint": f"{self.base}/oauth/mcp/authorize",
                "token_endpoint": f"{self.base}/oauth/mcp/token",
                "registration_endpoint": f"{self.base}/oauth/mcp/register",
                "response_types_supported": ["code"], "grant_types_supported": ["authorization_code"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": ["orchestration:read", "orchestration:operate"]})
        if path == "/oauth/mcp/register" and method == "POST":
            return self._register(h)
        if path == "/oauth/mcp/authorize" and method == "GET":
            return self._authorize(h)
        if path == "/oauth/mcp/token" and method == "POST":
            return self._token(h)
        self._send(h, 404, b"<html>not found</html>", content_type="text/html")

    def _register(self, h) -> None:
        body = json.loads(self._body(h) or b"{}")
        self.registrations.append(body)
        refused = [u for u in body.get("redirect_uris", []) if not self.accepts(u)]
        if refused:
            return self._send(h, 400, {
                "error": "invalid_redirect_uri",
                "error_description": self.refusal or f"redirect_uri not allowed: {refused[0]}"})
        self._send(h, 201, {**body, "client_id": f"client-{secrets.token_hex(4)}",
                            "token_endpoint_auth_method": "none"})

    def _authorize(self, h) -> None:
        query = {k: v[0] for k, v in parse_qs(urlsplit(h.path).query).items()}
        if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
            return self._send(h, 400, {"error": "invalid_request"})
        code = secrets.token_urlsafe(12)
        self.codes[code] = query["code_challenge"]
        separator = "&" if "?" in query["redirect_uri"] else "?"
        location = query["redirect_uri"] + separator + urlencode({"code": code, "state": query.get("state", "")})
        self._send(h, 302, None, headers={"Location": location})

    def _token(self, h) -> None:
        form = {k: v[0] for k, v in parse_qs(self._body(h).decode()).items()}
        self.token_requests.append(form)
        challenge = self.codes.pop(form.get("code", ""), None)
        verifier = form.get("code_verifier", "")
        digest = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        if form.get("grant_type") != "authorization_code" or challenge is None or digest != challenge:
            return self._send(h, 400, {"error": "invalid_grant"})
        token = f"t3-{secrets.token_hex(8)}"
        self.tokens.add(token)
        self._send(h, 200, {"access_token": token, "token_type": "Bearer", "expires_in": 3600})

    def _mcp(self, h, method: str) -> None:
        if self.mcp_behaviour == "html":
            self._body(h)
            return self._send(h, 200, b"<html><body>T3 web app</body></html>", content_type="text/html")
        if self.mcp_behaviour == "missing":
            self._body(h)
            return self._send(h, 404, b"<html>Cannot POST /mcp</html>", content_type="text/html")
        bearer = (h.headers.get("Authorization") or "").removeprefix("Bearer ")
        if bearer not in self.tokens:
            self._body(h)
            return self._send(h, 401, {"error": "unauthorized"}, headers={
                "WWW-Authenticate":
                    f'Bearer resource_metadata="{self.base}/.well-known/oauth-protected-resource/mcp"'})
        if method != "POST":
            return self._send(h, 405 if method == "GET" else 200)
        message = json.loads(self._body(h) or b"{}")
        rpc = message.get("method")
        if "id" not in message:
            return self._send(h, 202)
        if rpc == "initialize":
            result = {"protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "t3code", "version": "0.0.0"}}
        elif rpc == "tools/list":
            result = {"tools": TOOLS}
        else:
            return self._send(h, 200, {
                "jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "method not found"}})
        self._send(h, 200, {"jsonrpc": "2.0", "id": message["id"], "result": result})
