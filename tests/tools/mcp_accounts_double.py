from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from urllib.parse import parse_qs, urlencode, urlsplit

import hermes_yaml as yaml

from tests.tools.t3code_double import T3CodeDouble

TOOLS = [
    {"name": "whoami", "description": "Report which account this call was made as.",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
    {"name": "list_projects", "description": "List projects.",
     "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}},
     "annotations": {"readOnlyHint": True}},
    {"name": "create_item", "description": "Create an item.",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}}}},
]


@dataclass(frozen=True)
class McpRequest:
    rpc: str
    bearer: str
    account: str | None
    tool: str | None = None
    arguments: dict = field(default_factory=dict)


class AccountsDouble(T3CodeDouble):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.authorize_queries: list[dict[str, str]] = []
        self.account_by_token: dict[str, str] = {}
        self.account_by_code: dict[str, str] = {}
        self.signing_in_as: str | None = None
        self.mcp_requests: list[McpRequest] = []

    def sign_in_as(self, account: str) -> None:
        self.signing_in_as = account

    def issue_token(self, account: str) -> str:
        token = f"{account}-{secrets.token_hex(6)}"
        self.account_by_token[token] = account
        self.tokens.add(token)
        return token

    def revoke(self, account: str) -> None:
        for token in [t for t, a in self.account_by_token.items() if a == account]:
            self.tokens.discard(token)

    def tool_calls(self, tool: str) -> list[McpRequest]:
        return [r for r in self.mcp_requests if r.rpc == "tools/call" and r.tool == tool]

    def accounts_that_called(self, tool: str) -> list[str]:
        return [r.account for r in self.tool_calls(tool)]

    def _authorize(self, h) -> None:
        query = {k: v[0] for k, v in parse_qs(urlsplit(h.path).query).items()}
        self.authorize_queries.append(query)
        if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
            return self._send(h, 400, {"error": "invalid_request"})
        code = secrets.token_urlsafe(12)
        self.codes[code] = query["code_challenge"]
        self.account_by_code[code] = query.get("login_hint") or self.signing_in_as or "anonymous"
        separator = "&" if "?" in query["redirect_uri"] else "?"
        location = query["redirect_uri"] + separator + urlencode({"code": code, "state": query.get("state", "")})
        self._send(h, 302, None, headers={"Location": location})

    def _token(self, h) -> None:
        form = {k: v[0] for k, v in parse_qs(self._body(h).decode()).items()}
        self.token_requests.append(form)
        code = form.get("code", "")
        challenge = self.codes.pop(code, None)
        account = self.account_by_code.pop(code, None)
        digest = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).rstrip(b"=").decode()
        if form.get("grant_type") != "authorization_code" or challenge is None or digest != challenge or account is None:
            return self._send(h, 400, {"error": "invalid_grant"})
        self._send(h, 200, {"access_token": self.issue_token(account), "token_type": "Bearer", "expires_in": 3600})

    def _mcp(self, h, method: str) -> None:
        bearer = (h.headers.get("Authorization") or "").removeprefix("Bearer ")
        account = self.account_by_token.get(bearer) if bearer in self.tokens else None
        if account is None:
            self._body(h)
            self.mcp_requests.append(McpRequest("unauthorized", bearer, None))
            return self._send(h, 401, {"error": "unauthorized"}, headers={
                "WWW-Authenticate":
                    f'Bearer resource_metadata="{self.base}/.well-known/oauth-protected-resource/mcp"'})
        if method != "POST":
            return self._send(h, 405 if method == "GET" else 200)
        message = json.loads(self._body(h) or b"{}")
        rpc = message.get("method")
        params = message.get("params") or {}
        self.mcp_requests.append(McpRequest(
            rpc, bearer, account, params.get("name") if rpc == "tools/call" else None,
            dict(params.get("arguments") or {}) if rpc == "tools/call" else {}))
        if "id" not in message:
            return self._send(h, 202)
        if rpc == "initialize":
            result = {"protocolVersion": params["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "accounts-double", "version": "0.0.0"}}
        elif rpc == "tools/list":
            result = {"tools": TOOLS}
        elif rpc == "tools/call":
            text = json.dumps({"account": account, "tool": params.get("name"), "arguments": params.get("arguments") or {}})
            result = {"content": [{"type": "text", "text": text}]}
        else:
            return self._send(h, 200, {
                "jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "method not found"}})
        self._send(h, 200, {"jsonrpc": "2.0", "id": message["id"], "result": result})


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def follow_authorization(auth_url: str) -> dict[str, str]:
    opener = urllib.request.build_opener(NoRedirects)
    try:
        opener.open(auth_url, timeout=10)
    except urllib.error.HTTPError as redirect:
        query = parse_qs(urlsplit(redirect.headers["Location"]).query)
        return {k: v[0] for k, v in query.items()}
    raise AssertionError("the double's authorize endpoint did not redirect")


def store_account_tokens(double: AccountsDouble, server_name: str, account: str) -> str:
    from mcp.shared.auth import OAuthToken

    from tools.mcp_oauth import HermesTokenStorage

    token = double.issue_token(account)
    asyncio.run(HermesTokenStorage(server_name).set_tokens(
        OAuthToken(access_token=token, token_type="Bearer", expires_in=3600)))
    return token


def write_servers(home, double: AccountsDouble, slug: str, accounts: list[str] | None = None, **extra) -> None:
    template = {"url": double.mcp_url, "transport": "http", "auth": "oauth", **extra}
    if accounts is not None:
        template["accounts"] = {alias: {} for alias in accounts}
    (home / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {slug: template}}, sort_keys=False), encoding="utf-8")
