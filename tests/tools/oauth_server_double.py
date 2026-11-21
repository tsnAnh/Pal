from __future__ import annotations

import base64
import datetime
import hashlib
import ipaddress
import json
import secrets
import ssl
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

from tools.connectors.mcp_oauth_redirect import APP_REDIRECT_SCHEME

APP, GATEWAY, LOOPBACK = "app", "gateway", "loopback"
ALL_REDIRECT_KINDS = frozenset({APP, GATEWAY, LOOPBACK})
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def redirect_kind(uri: str) -> str | None:
    parts = urlsplit(uri)
    if parts.scheme == APP_REDIRECT_SCHEME:
        return APP
    if parts.scheme == "https":
        return GATEWAY
    if parts.scheme == "http" and parts.hostname in _LOOPBACK_HOSTS:
        return LOOPBACK
    return None


def pkce_challenge(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


@dataclass
class Grant:
    account: str
    client_id: str
    scope: str
    access_token: str
    refresh_token: str | None
    expires_at: float
    revoked: bool = False


@dataclass
class Client:
    client_id: str
    redirect_uris: list[str]
    secret: str | None = None


@dataclass
class PendingCode:
    challenge: str
    client_id: str
    redirect_uri: str
    account: str
    scope: str


@dataclass
class Registry:
    registrations: list[dict] = field(default_factory=list)
    authorize_queries: list[dict] = field(default_factory=list)
    token_requests: list[dict] = field(default_factory=list)
    refusals: list[dict] = field(default_factory=list)
    cimd_fetches: list[str] = field(default_factory=list)


def self_signed_certificate(directory: Path) -> Path:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    now = datetime.datetime.now(datetime.UTC)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    path = directory / "authorization-server.pem"
    path.write_bytes(
        cert.public_bytes(serialization.Encoding.PEM)
        + key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return path


class OAuthServerDouble:
    def __init__(
        self,
        *,
        dcr: bool = True,
        accepted_redirects: frozenset[str] = ALL_REDIRECT_KINDS,
        issue_refresh: bool = True,
        expires_in: int = 3600,
        cimd: bool = False,
        tls: bool = False,
        refusal: str | None = None,
        document_fetcher: Callable[[str], dict | None] | None = None,
    ):
        self.dcr = dcr
        self.accepted_redirects = accepted_redirects
        self.issue_refresh = issue_refresh
        self.expires_in = expires_in
        self.cimd = cimd
        self.refusal = refusal
        self.document_fetcher = document_fetcher
        self.signing_in_as = "owner"
        self.clients: dict[str, Client] = {}
        self.client_documents: dict[str, dict] = {}
        self.codes: dict[str, PendingCode] = {}
        self.grants_by_access: dict[str, Grant] = {}
        self.grants_by_refresh: dict[str, Grant] = {}
        self.log = Registry()
        self._lock = threading.RLock()
        self._tls_dir = tempfile.TemporaryDirectory(prefix="oauth-double-") if tls else None
        self.cert_path = self_signed_certificate(Path(self._tls_dir.name)) if tls else None
        double = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_GET(self):
                double._route(self, "GET")

            def do_POST(self):
                double._route(self, "POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        if tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(self.cert_path)
            self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.port = self.server.server_address[1]
        self.base = f"{'https' if tls else 'http'}://127.0.0.1:{self.port}"
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)

    def start(self) -> OAuthServerDouble:
        self._thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        if self._tls_dir is not None:
            self._tls_dir.cleanup()

    def __enter__(self) -> OAuthServerDouble:
        return self.start()

    def __exit__(self, *_exc) -> None:
        self.stop()

    @property
    def registrations(self) -> list[dict]:
        return self.log.registrations

    @property
    def authorize_queries(self) -> list[dict]:
        return self.log.authorize_queries

    @property
    def token_requests(self) -> list[dict]:
        return self.log.token_requests

    def grant_requests(self, grant_type: str) -> list[dict]:
        return [r for r in self.log.token_requests if r.get("grant_type") == grant_type]

    def sign_in_as(self, account: str) -> None:
        self.signing_in_as = account

    def publish_client_document(self, name: str, redirect_uris: list[str]) -> str:
        url = f"{self.base}/clients/{name}"
        self.client_documents[name] = {"client_id": url, "client_name": name, "redirect_uris": redirect_uris,
                                       "token_endpoint_auth_method": "none"}
        return url

    def preregister(self, client_id: str, secret: str | None, redirect_uris: list[str]) -> None:
        self.clients[client_id] = Client(client_id, list(redirect_uris), secret)

    def verify(self, access_token: str) -> Grant | None:
        with self._lock:
            grant = self.grants_by_access.get(access_token)
        if grant is None or grant.revoked or grant.expires_at <= time.time():
            return None
        return grant

    def expire_access_tokens(self, account: str | None = None) -> None:
        with self._lock:
            for grant in self.grants_by_access.values():
                if account is None or grant.account == account:
                    grant.revoked = True

    def forget_refresh_tokens(self) -> None:
        with self._lock:
            self.grants_by_refresh.clear()

    def tokens_of(self, account: str) -> list[Grant]:
        with self._lock:
            return [g for g in self.grants_by_access.values() if g.account == account]

    def metadata(self) -> dict:
        auth_methods = ["none", "client_secret_post", "client_secret_basic"]
        document = {
            "issuer": self.base, "authorization_endpoint": f"{self.base}/authorize", "token_endpoint": f"{self.base}/token",
            "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": auth_methods}
        if self.dcr:
            document["registration_endpoint"] = f"{self.base}/register"
        if self.cimd:
            document["client_id_metadata_document_supported"] = True
        return document

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
        if path == "/.well-known/oauth-authorization-server" and method == "GET":
            return self._send(h, 200, self.metadata())
        if path.startswith("/clients/") and method == "GET" and path[9:] in self.client_documents:
            return self._send(h, 200, self.client_documents[path[9:]])
        if path == "/register" and method == "POST" and self.dcr:
            return self._register(h)
        if path == "/authorize" and method == "GET":
            return self._authorize(h)
        if path == "/token" and method == "POST":
            return self._token(h)
        self._body(h)
        self._send(h, 404, b"<html>not found</html>", content_type="text/html")

    def _redirect_accepted(self, uri: str) -> bool:
        return redirect_kind(uri) in self.accepted_redirects

    def _register(self, h) -> None:
        body = json.loads(self._body(h) or b"{}")
        self.log.registrations.append(body)
        refused = [u for u in body.get("redirect_uris", []) if not self._redirect_accepted(u)]
        if refused:
            self.log.refusals.append({"redirect_uri": refused[0]})
            return self._send(h, 400, {
                "error": "invalid_redirect_uri",
                "error_description": self.refusal or f"redirect_uri not allowed: {refused[0]}"})
        client_id = f"client-{secrets.token_hex(4)}"
        self.clients[client_id] = Client(client_id, list(body.get("redirect_uris", [])))
        self._send(h, 201, {**body, "client_id": client_id, "token_endpoint_auth_method": "none"})

    def _client_for(self, client_id: str, redirect_uri: str) -> Client | None:
        if client_id in self.clients:
            return self.clients[client_id]
        if self.cimd and client_id.startswith(("https://", "http://")):
            return self._client_from_document(client_id, redirect_uri)
        return None

    def _client_from_document(self, client_id: str, redirect_uri: str) -> Client | None:
        self.log.cimd_fetches.append(client_id)
        try:
            document = self._fetch_document(client_id)
        except (OSError, ValueError, urllib.error.URLError):
            return None
        if not isinstance(document, dict) or document.get("client_id") != client_id:
            return None
        client = Client(client_id, list(document.get("redirect_uris") or []))
        self.clients[client_id] = client
        return client

    def _fetch_document(self, client_id: str) -> dict | None:
        if self.document_fetcher is not None:
            return self.document_fetcher(client_id)
        context = ssl.create_default_context(cafile=str(self.cert_path)) if self.cert_path else None
        with urllib.request.urlopen(client_id, timeout=10, context=context) as response:
            return json.loads(response.read())

    def _authorize(self, h) -> None:
        query = {k: v[0] for k, v in parse_qs(urlsplit(h.path).query).items()}
        self.log.authorize_queries.append(query)
        redirect_uri = query.get("redirect_uri", "")
        client = self._client_for(query.get("client_id", ""), redirect_uri)
        if client is None:
            return self._send(h, 400, {"error": "invalid_client"})
        if redirect_uri not in client.redirect_uris or not self._redirect_accepted(redirect_uri):
            return self._send(h, 400, {"error": "invalid_request", "error_description": "redirect_uri mismatch"})
        if query.get("response_type") != "code" or query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
            return self._send(h, 400, {"error": "invalid_request"})
        code = secrets.token_urlsafe(12)
        with self._lock:
            self.codes[code] = PendingCode(
                query["code_challenge"], client.client_id, redirect_uri,
                query.get("login_hint") or self.signing_in_as, query.get("scope", ""))
        separator = "&" if "?" in redirect_uri else "?"
        location = redirect_uri + separator + urlencode({"code": code, "state": query.get("state", ""), "iss": self.base})
        self._send(h, 302, None, headers={"Location": location})

    def _client_credentials(self, h, form: dict) -> tuple[str, str | None]:
        header = h.headers.get("Authorization") or ""
        if header.lower().startswith("basic "):
            user, _, secret = base64.b64decode(header[6:]).decode().partition(":")
            return user, secret
        return form.get("client_id", ""), form.get("client_secret")

    def _token(self, h) -> None:
        form = {k: v[0] for k, v in parse_qs(self._body(h).decode()).items()}
        self.log.token_requests.append(dict(form))
        client_id, secret = self._client_credentials(h, form)
        client = self.clients.get(client_id)
        if client is None or (client.secret is not None and secret != client.secret):
            return self._send(h, 401, {"error": "invalid_client"})
        grant_type = form.get("grant_type")
        if grant_type == "authorization_code":
            return self._code_grant(h, form, client)
        if grant_type == "refresh_token":
            return self._refresh_grant(h, form, client)
        self._send(h, 400, {"error": "unsupported_grant_type"})

    def _code_grant(self, h, form: dict, client: Client) -> None:
        with self._lock:
            pending = self.codes.pop(form.get("code", ""), None)
        valid = (pending is not None and pending.client_id == client.client_id
                 and pkce_challenge(form.get("code_verifier", "")) == pending.challenge
                 and form.get("redirect_uri") == pending.redirect_uri)
        if not valid:
            return self._send(h, 400, {"error": "invalid_grant"})
        self._send(h, 200, self._issue(pending.account, client.client_id, pending.scope))

    def _refresh_grant(self, h, form: dict, client: Client) -> None:
        with self._lock:
            previous = self.grants_by_refresh.pop(form.get("refresh_token", ""), None)
        if previous is None or previous.client_id != client.client_id:
            return self._send(h, 400, {"error": "invalid_grant"})
        self._send(h, 200, self._issue(previous.account, client.client_id, previous.scope))

    def _issue(self, account: str, client_id: str, scope: str) -> dict:
        grant = Grant(account, client_id, scope, f"at-{account}-{secrets.token_hex(6)}",
                      f"rt-{account}-{secrets.token_hex(6)}" if self.issue_refresh else None,
                      time.time() + self.expires_in)
        with self._lock:
            self.grants_by_access[grant.access_token] = grant
            if grant.refresh_token:
                self.grants_by_refresh[grant.refresh_token] = grant
        body = {"access_token": grant.access_token, "token_type": "Bearer", "expires_in": self.expires_in}
        if grant.refresh_token:
            body["refresh_token"] = grant.refresh_token
        if scope:
            body["scope"] = scope
        return body
