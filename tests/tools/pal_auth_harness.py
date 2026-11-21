from __future__ import annotations

import asyncio
import datetime
import ipaddress
import json
import os
import secrets
import socket
import ssl
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

import hermes_yaml as yaml
import pytest
import pytest_asyncio

from hermes_constants import get_hermes_home
from tests.tools.oauth_server_double import pkce_challenge
from tests.waiting import wait_until
from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_URI, GATEWAY_CALLBACK_PATH
from tools.mcp_tool_schema import mcp_prefixed_tool_name

ARTIFACT_DIR = Path(__file__).resolve().parents[2] / "test-results" / "pal-auth-e2e"
LOCAL_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
NOUS_MARKERS = ("nousresearch.com", "nousresearch.github.io", "nous")
PUBLIC_URL = "https://pal.example.com"
LOOPBACK_REDIRECT = "http://127.0.0.1:53682/callback"

_OUTCOME = pytest.StashKey[str]()
_GOOD = frozenset({"passed", "xfailed"})


class NetworkGuard:
    def __init__(self, monkeypatch: pytest.MonkeyPatch):
        self.hosts: list[str] = []
        self.refused: list[str] = []
        real_getaddrinfo = socket.getaddrinfo
        real_create_connection = socket.create_connection
        real_connect = socket.socket.connect
        real_connect_ex = socket.socket.connect_ex
        guard = self

        def getaddrinfo(host, *args, **kwargs):
            guard.note(host)
            return real_getaddrinfo(host, *args, **kwargs)

        def create_connection(address, *args, **kwargs):
            guard.note(address[0])
            return real_create_connection(address, *args, **kwargs)

        def connect(sock, address):
            guard.note(address)
            return real_connect(sock, address)

        def connect_ex(sock, address):
            guard.note(address)
            return real_connect_ex(sock, address)

        monkeypatch.setattr(socket, "getaddrinfo", getaddrinfo)
        monkeypatch.setattr(socket, "create_connection", create_connection)
        monkeypatch.setattr(socket.socket, "connect", connect)
        monkeypatch.setattr(socket.socket, "connect_ex", connect_ex)

    def note(self, target) -> None:
        host = target[0] if isinstance(target, tuple) else target
        if not isinstance(host, str):
            return
        if host not in self.hosts:
            self.hosts.append(host)
        if not _is_local(host) and host not in self.refused:
            self.refused.append(host)
            raise ConnectionRefusedError(f"test left this machine: {host}")

    def assert_stayed_home(self) -> None:
        nous = [h for h in self.hosts if any(marker in h.lower() for marker in NOUS_MARKERS)]
        assert not nous, f"a Nous host was contacted: {nous}"
        assert not self.refused, f"traffic left 127.0.0.1: {self.refused}"


def _is_local(host: str) -> bool:
    if host in LOCAL_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _run_stamp() -> str:
    import psutil

    started = psutil.Process(os.getppid()).create_time()
    return datetime.datetime.fromtimestamp(started, datetime.UTC).strftime("%Y%m%dT%H%M%SZ")


def _record(shape: str, test_id: str, outcome: str, hosts: list[str], hosted: bool) -> Path:
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = _run_stamp()
    target, lock = ARTIFACT_DIR / f"{stamp}.json", ARTIFACT_DIR / f".{stamp}.lock"

    def take_lock() -> bool:
        try:
            os.close(os.open(lock, os.O_CREAT | os.O_EXCL))
            return True
        except FileExistsError:
            return False

    wait_until(take_lock, timeout=30, what="artifact lock")
    try:
        document = json.loads(target.read_text()) if target.exists() else {"run": stamp, "shapes": {}}
        entry = document["shapes"].setdefault(shape, {"result": "pass", "tests": {}, "hosts_contacted": []})
        entry["tests"][test_id] = {"outcome": outcome, "connectors_hosted": hosted, "hosts_contacted": sorted(hosts)}
        entry["result"] = "pass" if all(t["outcome"] in _GOOD for t in entry["tests"].values()) else "fail"
        entry["hosts_contacted"] = sorted({h for t in entry["tests"].values() for h in t["hosts_contacted"]})
        document["result"] = "pass" if all(s["result"] == "pass" for s in document["shapes"].values()) else "fail"
        staging = target.with_suffix(".tmp")
        staging.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
        os.replace(staging, target)
    finally:
        os.unlink(lock)
    return target


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    if report.when == "call" or (report.when == "setup" and report.outcome != "passed"):
        item.stash[_OUTCOME] = "xfailed" if hasattr(report, "wasxfail") else report.outcome


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class Browser:
    def __init__(self, ca_file: Path | None = None):
        self.context = ssl.create_default_context(cafile=str(ca_file)) if ca_file else None

    def authorize(self, auth_url: str) -> dict[str, str]:
        handlers: list = [_NoRedirects()]
        if self.context is not None:
            handlers.append(urllib.request.HTTPSHandler(context=self.context))
        try:
            urllib.request.build_opener(*handlers).open(auth_url, timeout=10)
        except urllib.error.HTTPError as redirect:
            location = redirect.headers.get("Location")
            if location is None:
                raise AssertionError(f"the authorization page answered {redirect.code}: {redirect.read()!r}") from None
            return {k: v[0] for k, v in parse_qs(urlsplit(location).query).items()}
        raise AssertionError("the authorization page did not redirect")


def gateway_callback(landed: dict[str, str]):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from hermes_cli.web_routers import mcp_oauth_callback

    app = FastAPI()
    app.include_router(mcp_oauth_callback.router)
    return TestClient(app, base_url=PUBLIC_URL).get(GATEWAY_CALLBACK_PATH, params=landed)


def gateway_document_fetcher(public_url: str = PUBLIC_URL):
    def fetch(url: str) -> dict | None:
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        from hermes_cli.web_routers import oauth_client_metadata

        parts = urlsplit(url)
        if f"{parts.scheme}://{parts.netloc}" != public_url:
            return None
        app = FastAPI()
        app.include_router(oauth_client_metadata.router)
        reply = TestClient(app, base_url=public_url).get(parts.path)
        return reply.json() if reply.status_code == 200 else None

    return fetch


def device_sign_in(authorization, *, account: str | None = None, redirect_uri: str = LOOPBACK_REDIRECT,
                   scope: str = "") -> dict:
    if account:
        authorization.sign_in_as(account)
    context = ssl.create_default_context(cafile=str(authorization.cert_path)) if authorization.cert_path else None

    def post(url: str, body: bytes, content_type: str) -> dict:
        request = urllib.request.Request(url, data=body, headers={"Content-Type": content_type})
        with urllib.request.urlopen(request, timeout=10, context=context) as response:
            return json.loads(response.read())

    registered = post(f"{authorization.base}/register", json.dumps({
        "client_name": "Pal device", "redirect_uris": [redirect_uri], "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}).encode(), "application/json")
    verifier = secrets.token_urlsafe(48)
    query = {"response_type": "code", "client_id": registered["client_id"], "redirect_uri": redirect_uri,
             "state": secrets.token_urlsafe(12), "code_challenge": pkce_challenge(verifier),
             "code_challenge_method": "S256", **({"scope": scope} if scope else {})}
    landed = Browser(authorization.cert_path).authorize(f"{authorization.base}/authorize?{urlencode(query)}")
    assert landed["state"] == query["state"]
    tokens = post(f"{authorization.base}/token", urlencode({
        "grant_type": "authorization_code", "code": landed["code"], "code_verifier": verifier,
        "client_id": registered["client_id"], "redirect_uri": redirect_uri}).encode(), "application/x-www-form-urlencoded")
    return {"client_id": registered["client_id"], "redirect_uri": redirect_uri,
            "token_endpoint": f"{authorization.base}/token", "issuer": authorization.base,
            "access_token": tokens["access_token"], "token_type": tokens["token_type"],
            "expires_in": tokens["expires_in"], **{k: tokens[k] for k in ("refresh_token", "scope") if k in tokens}}


class PalEnv:
    def __init__(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path, hosted: bool, guard: NetworkGuard):
        from tools.connectors.hosted_switch import hosted_enabled
        from tui_gateway import server

        self.home = get_hermes_home()
        self.hosted = hosted
        self.guard = guard
        self.monkeypatch = monkeypatch
        self._server = server
        self._catalog: list[dict] = []
        self._manifests = tmp_path / "optional-mcps"
        self._manifests.mkdir()
        self._catalog_file = tmp_path / "pal_connectors.yaml"
        monkeypatch.setenv("HERMES_OPTIONAL_MCPS", str(self._manifests))
        self.write_config({"connectors": {"hosted": False}} if not hosted else {})
        self.publish_catalog()
        assert hosted_enabled() is hosted

    def write_config(self, sections: dict) -> None:
        path = self.home / "config.yaml"
        current = yaml.safe_load(path.read_text()) if path.exists() else {}
        path.write_text(yaml.safe_dump({**(current or {}), **sections}, sort_keys=False))

    def read_config(self) -> dict:
        return yaml.safe_load((self.home / "config.yaml").read_text()) or {}

    def set_public_url(self, url: str = PUBLIC_URL) -> None:
        self.write_config({"webapp": {"public_url": url}})

    def add_connector(self, slug: str, method: str, mcp_url: str, *, signin_on: str | None = None,
                      oauth_endpoints: dict | None = None, scopes: list[str] | None = None,
                      sign_in: str | None = None, cimd: bool = False) -> None:
        entry = {"id": slug, "name": slug.title(), "description": f"{slug} test connector", "icon": "plugin_glyph",
                 "category": "Testing", "method": method, "mcp_url": mcp_url, "verified": False,
                 "source": "https://example.invalid/pal-auth-e2e"}
        if oauth_endpoints:
            entry["oauth"] = oauth_endpoints
        if scopes:
            entry["scopes"] = scopes
        if sign_in:
            entry["sign_in"] = sign_in
        if cimd:
            entry["cimd"] = True
        self._catalog.append(entry)
        if method in {"mcp_oauth", "api_key", "none", "oauth_client"}:
            manifest = {"manifest_version": 1, "name": slug, "description": f"{slug} test connector",
                        "transport": {"type": "http", "url": mcp_url}}
            manifest["auth"] = {"type": {"mcp_oauth": "oauth", "oauth_client": "oauth", "api_key": "api_key", "none": "none"}[method]}
            if signin_on:
                manifest["auth"]["signin_on"] = signin_on
            if method == "api_key":
                manifest["auth"]["env"] = [{"name": f"MCP_{slug.upper()}_API_KEY", "prompt": f"{slug} API key"}]
            folder = self._manifests / slug
            folder.mkdir(exist_ok=True)
            (folder / "manifest.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False))
        self.publish_catalog()

    def publish_catalog(self) -> None:
        from hermes_cli import pal_connectors

        self._catalog_file.write_text(yaml.safe_dump({"version": 1, "connectors": self._catalog}, sort_keys=False))
        self.monkeypatch.setattr(pal_connectors.load_pal_connectors, "__defaults__", (self._catalog_file,))
        pal_connectors.device_sign_in_urls.cache_clear()

    def rpc(self, method: str, **params) -> dict:
        reply = self._server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        assert "error" not in reply, f"{method}: {reply.get('error')}"
        return reply["result"]

    def rpc_error(self, method: str, **params) -> dict:
        reply = self._server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        assert "error" in reply, f"{method} unexpectedly succeeded: {reply}"
        return reply["error"]

    def connector_row(self, slug: str) -> dict:
        rows = self.rpc("connectors.catalog")["connectors"]
        return next(row for row in rows if row["slug"] == slug)

    def poll_until(self, name: str, session_id: str, status: str = "approved", **scope) -> dict:
        return wait_until(
            lambda: (p := self.rpc("mcp.servers.oauth.poll", name=name, session_id=session_id, **scope))["status"] == status and p,
            what=f"{name} sign-in {status}")

    def sign_in_with_app_redirect(self, slug: str, ca_file: Path | None = None, **start_params) -> dict:
        started = self.rpc("mcp.servers.oauth.start", name=slug, client_redirect_uri=APP_REDIRECT_URI, **start_params)
        landed = Browser(ca_file).authorize(started["auth_url"])
        scope = {k: v for k, v in start_params.items() if k == "account"}
        self.rpc("mcp.servers.oauth.callback", name=slug, session_id=started["session_id"],
                 code=landed["code"], state=landed["state"], iss=landed.get("iss", ""), **scope)
        self.poll_until(slug, started["session_id"], **scope)
        return started

    def start_agent_tools(self) -> list[str]:
        from tools.mcp_tool_discovery import discover_mcp_tools

        return discover_mcp_tools()

    @staticmethod
    def tool(slug: str, name: str) -> str:
        return mcp_prefixed_tool_name(slug, name)

    def call(self, slug: str, tool: str, **arguments) -> dict:
        from tools.registry import registry

        return json.loads(registry.dispatch(self.tool(slug, tool), arguments))

    def shutdown(self) -> None:
        from hermes_cli import pal_connectors
        from tools import mcp_tool_loop as loop
        from tools.mcp_oauth_manager import reset_manager_for_tests
        from tools.mcp_tool_lifecycle import shutdown_mcp_servers

        shutdown_mcp_servers()
        loop._stop_mcp_loop()
        reset_manager_for_tests()
        pal_connectors.device_sign_in_urls.cache_clear()


async def hand_over(phone, authorization, service: str, account: str | None = None, **overrides) -> dict:
    handover = {**device_sign_in(authorization, account=account), **overrides}
    return await phone.call("auth.submit_oauth_tokens", {"service": service, **handover})


async def agent(pal: PalEnv, slug: str, tool: str, **arguments) -> dict:
    return await asyncio.to_thread(pal.call, slug, tool, **arguments)


@pytest_asyncio.fixture
async def phone(pal):
    from tests.gateway.device_tools_harness import connect_phone, make_authority, release_authority

    authority = await make_authority(pal.home)
    yield await connect_phone(authority)
    release_authority(authority)


@pytest.fixture
def guard(monkeypatch):
    guard = NetworkGuard(monkeypatch)
    yield guard
    guard.assert_stayed_home()


@pytest.fixture(params=[True, False], ids=["hosted-default", "hosted-off"])
def pal(request, monkeypatch, tmp_path):
    from tools.mcp_oauth_manager import reset_manager_for_tests
    from tui_gateway import mcp_oauth_sessions as sessions

    pytest.importorskip("mcp.client.auth.oauth2")
    reset_manager_for_tests()
    monkeypatch.setattr(sessions, "_sessions", {})
    env = PalEnv(monkeypatch, tmp_path, hosted=request.param, guard=NetworkGuard(monkeypatch))
    yield env
    env.shutdown()
    outcome = request.node.stash.get(_OUTCOME, "error")
    try:
        env.guard.assert_stayed_home()
    except AssertionError:
        outcome = "failed"
        raise
    finally:
        _record(request.module.SHAPE, request.node.name, outcome, env.guard.hosts, env.hosted)
