from __future__ import annotations

import asyncio
import logging
import threading
from pathlib import Path
from typing import Callable, Optional, Protocol

logger = logging.getLogger(__name__)


class SigninFlow(Protocol):
    kind: str
    user_code: Optional[str]
    verification_uri: Optional[str]
    expires_in: Optional[int]

    async def begin(self) -> None: ...

    async def authorize_url(self) -> Optional[str]: ...

    async def wait(self) -> bool: ...

    def cancel(self) -> None: ...


CONNECT_APP_SOURCES = {
    "hosted": "connector:<slug> -> oauth through the connector portal (CONNECTION_REQUIRED / CONNECTION_EXPIRED)",
    "mcp": "mcp:<server> -> oauth, api_key or header from the server config (manifest auth.type for catalog presets)",
    "custom": "custom connector -> HTTP header values entered in the app's connector form, no sign-in flow",
}

FlowFactory = Callable[[Path, str], SigninFlow]
_factories: dict[str, FlowFactory] = {}


def register(prefix: str, factory: FlowFactory) -> None:
    _factories[prefix] = factory


def unregister(prefix: str) -> None:
    _factories.pop(prefix, None)


def flow_for(home: Path, service: str) -> SigninFlow:
    factory = _factories.get(service) or _factories.get(service.partition(":")[0])
    return factory(home, service) if factory is not None else ManualFlow()


def classify_mcp_server(cfg: object) -> str:
    if not isinstance(cfg, dict):
        return "manual"
    if cfg.get("auth") == "oauth":
        return "oauth"
    headers = cfg.get("headers")
    if isinstance(headers, dict) and headers:
        bearer = headers.get("Authorization") or headers.get("authorization")
        only_bearer = len(headers) == 1 and isinstance(bearer, str) and bearer.startswith("Bearer ${")
        return "api_key" if only_bearer else "header"
    return "oauth" if cfg.get("url") else "manual"


class ManualFlow:
    kind = "manual"
    user_code = None
    verification_uri = None
    expires_in = None

    def __init__(self) -> None:
        self._cancelled = asyncio.Event()

    async def begin(self) -> None:
        return None

    async def authorize_url(self) -> Optional[str]:
        return None

    async def wait(self) -> bool:
        await self._cancelled.wait()
        return False

    def cancel(self) -> None:
        self._cancelled.set()


class GithubDeviceFlow:
    kind = "device_code"

    def __init__(self, home: Path, service: str = "github") -> None:
        self._home = home
        self._cancelled = threading.Event()
        self._client_id = ""
        self._code = None
        self.user_code: Optional[str] = None
        self.verification_uri: Optional[str] = None
        self.expires_in: Optional[int] = None

    async def begin(self) -> None:
        from hermes_cli import github_device_flow as gh_flow
        self._client_id = await asyncio.to_thread(gh_flow.configured_client_id, self._home)
        self._code = await asyncio.to_thread(gh_flow.request_device_code, self._client_id)
        self.user_code, self.verification_uri = self._code.user_code, self._code.verification_uri
        self.expires_in = self._code.expires_in

    async def authorize_url(self) -> Optional[str]:
        return None

    async def wait(self) -> bool:
        from hermes_cli import github_device_flow as gh_flow
        try:
            token = await asyncio.to_thread(gh_flow.poll_for_token, self._client_id, self._code,
                                            cancelled=self._cancelled.is_set)
            await asyncio.to_thread(gh_flow.store_token_with_gh, token)
        except gh_flow.GithubSigninError as exc:
            logger.warning("GitHub sign-in did not complete: %s", exc)
            return False
        return True

    def cancel(self) -> None:
        self._cancelled.set()


class McpOAuthFlow:
    kind = "oauth"
    user_code = None
    verification_uri = None
    expires_in = None
    accepts_redirect = True
    failure: Optional[str] = None
    POLL_SECONDS = 1.5

    def __init__(self, home: Path, service: str) -> None:
        self._home = home
        self._server = service.partition(":")[2]
        self._session_id: Optional[str] = None
        self._started = asyncio.Event()
        self._cancelled = False

    def _home_key(self) -> str:
        return str(Path(self._home).expanduser().resolve(strict=False))

    async def begin(self) -> None:
        return None

    async def authorize_url(self) -> Optional[str]:
        from hermes_cli.mcp_config import _get_mcp_servers
        from tui_gateway import mcp_oauth_sessions
        servers = await asyncio.to_thread(_get_mcp_servers)
        cfg = servers.get(self._server)
        if not isinstance(cfg, dict) or not cfg.get("url"):
            return None
        home = await asyncio.to_thread(self._home_key)
        started = await asyncio.to_thread(mcp_oauth_sessions.start_flow, home, self._server, {**cfg, "auth": "oauth"})
        self._session_id = started["session_id"]
        self._started.set()
        return started["auth_url"]

    async def wait(self) -> bool:
        from tui_gateway import mcp_oauth_sessions
        await self._started.wait()
        while not self._cancelled and self._session_id:
            status_row = mcp_oauth_sessions.poll_flow(self._session_id, self._server)
            status = status_row.get("status")
            if status == "approved":
                return True
            if status == "error":
                if "access_denied" in str(status_row.get("error_message") or ""):
                    self.failure = "Sign-in was declined on the provider's page."
                return False
            await asyncio.sleep(self.POLL_SECONDS)
        return False

    async def submit_redirect(self, value: str) -> bool:
        from tui_gateway import mcp_oauth_sessions
        if not self._session_id:
            return False
        outcome = await asyncio.to_thread(
            mcp_oauth_sessions.deliver_pasted_redirect, self._session_id, self._server, self._home_key(), value)
        return outcome["ok"]

    def cancel(self) -> None:
        self._cancelled = True
        self._started.set()
        if self._session_id:
            from tui_gateway import mcp_oauth_sessions
            mcp_oauth_sessions.cancel_flow(self._session_id, self._server, self._home_key())


MAX_CREDENTIAL_CHARS = 4096


def credential_text(value: object) -> Optional[str]:
    """The single-line ASCII credential to save, or None when it cannot be one (HTTP header values are ASCII,
    and ``save_env_value`` prints the offending characters of a non-ASCII value to stderr)."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or len(text) > MAX_CREDENTIAL_CHARS or not text.isascii() or not text.isprintable():
        return None
    return text


async def save_credential(env_var: str, text: str) -> None:
    from hermes_cli.config import save_env_value_secure
    await asyncio.to_thread(save_env_value_secure, env_var, text)


class KeyEntryFlow:
    kind = "api_key"
    user_code = None
    verification_uri = None
    expires_in = None

    def __init__(self, server: str) -> None:
        self.server = server
        self._stored = asyncio.Event()

    async def store(self, value: str) -> bool:
        from hermes_cli.mcp_config import _env_key_for_server, _strip_bearer_prefix
        text = credential_text(value)
        text = _strip_bearer_prefix(text) if text else None
        if not text or text.lower() == "bearer":
            return False
        await save_credential(_env_key_for_server(self.server), text)
        self._stored.set()
        return True

    async def begin(self) -> None:
        return None

    async def authorize_url(self) -> Optional[str]:
        return None

    async def confirm(self) -> bool:
        from hermes_cli.config import get_env_value
        from hermes_cli.mcp_config import _env_key_for_server
        if not await asyncio.to_thread(get_env_value, _env_key_for_server(self.server)):
            return False
        self._stored.set()
        return True

    async def wait(self) -> bool:
        await self._stored.wait()
        return True

    def cancel(self) -> None:
        return None


class HeaderFlow:
    kind = "header"
    user_code = None
    verification_uri = None
    expires_in = None

    def __init__(self, server: str, env_var: str) -> None:
        self.server = server
        self._env_var = env_var
        self._stored = asyncio.Event()

    async def begin(self) -> None:
        return None

    async def authorize_url(self) -> Optional[str]:
        return None

    async def store(self, value: str) -> bool:
        text = credential_text(value)
        if text is None:
            return False
        await save_credential(self._env_var, text)
        self._stored.set()
        return True

    async def wait(self) -> bool:
        await self._stored.wait()
        return True

    def cancel(self) -> None:
        return None


class McpServerFlow:
    user_code = None
    verification_uri = None
    expires_in = None

    def __init__(self, home: Path, service: str) -> None:
        self._home = home
        self._server = service.partition(":")[2]
        self._inner: SigninFlow = ManualFlow()

    @property
    def kind(self) -> str:
        return self._inner.kind

    @property
    def server(self) -> str:
        return self._server

    async def begin(self) -> None:
        from hermes_cli.mcp_config import _get_mcp_servers
        cfg = (await asyncio.to_thread(_get_mcp_servers)).get(self._server)
        kind = classify_mcp_server(cfg)
        if kind == "oauth":
            self._inner = McpOAuthFlow(self._home, f"mcp:{self._server}")
        elif kind == "api_key":
            self._inner = KeyEntryFlow(self._server)
        elif kind == "header":
            from tui_gateway.mcp_header_secrets import referenced_vars
            names = referenced_vars(cfg.get("headers"))
            if len(names) == 1:
                self._inner = HeaderFlow(self._server, next(iter(names)))

    async def authorize_url(self) -> Optional[str]:
        return await self._inner.authorize_url()

    @property
    def store(self):
        return getattr(self._inner, "store", None)

    @property
    def accepts_redirect(self) -> bool:
        return getattr(self._inner, "accepts_redirect", False)

    @property
    def failure(self) -> Optional[str]:
        return getattr(self._inner, "failure", None)

    async def submit_redirect(self, value: str) -> bool:
        return await self._inner.submit_redirect(value)

    async def confirm(self) -> bool:
        confirm = getattr(self._inner, "confirm", None)
        return await confirm() if confirm is not None else True

    async def wait(self) -> bool:
        return await self._inner.wait()

    def cancel(self) -> None:
        self._inner.cancel()


class HostedConnectorFlow:
    kind = "oauth"
    user_code = None
    verification_uri = None
    expires_in = None
    POLL_SECONDS = 3.0

    def __init__(self, home: Path, service: str) -> None:
        self._slug = service.partition(":")[2]
        self._started = asyncio.Event()
        self._cancelled = False
        self.already_connected = False

    async def begin(self) -> None:
        return None

    def _mint(self) -> Optional[str]:
        from tools.connectors.gateway.client import return_to_args
        from tools.connectors.managed import managed_client
        client = managed_client(creates_guest=False)
        response = client.connections([self._slug], reinitiate=True, alias=None, connection_id=None, **return_to_args())
        for entry in response.get("results", []):
            if str(entry.get("connector") or "").lower() != self._slug:
                continue
            if entry.get("status") == "active":
                self.already_connected = True
                return None
            url = entry.get("connect_url")
            return url if isinstance(url, str) and url.startswith("https://") else None
        return None

    def _connected(self) -> bool:
        from tools.connectors.managed import managed_client
        rows = managed_client(creates_guest=False).list_connectors()
        return any(str(r.get("connector", "")).lower() == self._slug and r.get("connected") is True
                   and r.get("connection_status") in (None, "active") for r in rows if isinstance(r, dict))

    async def authorize_url(self) -> Optional[str]:
        url = await asyncio.to_thread(self._mint)
        self._started.set()
        return url

    async def wait(self) -> bool:
        await self._started.wait()
        while not self._cancelled:
            if self.already_connected or await asyncio.to_thread(self._connected):
                return True
            await asyncio.sleep(self.POLL_SECONDS)
        return False

    def cancel(self) -> None:
        self._cancelled = True
        self._started.set()


class ProviderKeyFlow:
    kind = "api_key"
    user_code = None
    verification_uri = None
    expires_in = None
    failure: Optional[str] = None

    def __init__(self, provider: str) -> None:
        self.provider = provider
        self._stored = asyncio.Event()

    async def store(self, value: str) -> bool:
        from hermes_cli import model_provider_control as control
        text = credential_text(value)
        if text is None:
            return False
        await asyncio.to_thread(control.store_api_key, self.provider, text)
        self._stored.set()
        return True

    async def begin(self) -> None:
        return None

    async def authorize_url(self) -> Optional[str]:
        return None

    async def wait(self) -> bool:
        await self._stored.wait()
        return True

    def cancel(self) -> None:
        return None


class ProviderDeviceFlow:
    kind = "device_code"
    POLL_SECONDS = 1.0
    FAILURES = {"denied": "Sign-in was declined on the provider's page.",
                "expired": "The sign-in code expired. Start again for a new one.",
                "cancelled": "Sign-in was cancelled."}

    def __init__(self, home: Path, provider: str) -> None:
        self._home = home
        self.provider = provider
        self._session_id: Optional[str] = None
        self.user_code: Optional[str] = None
        self.verification_uri: Optional[str] = None
        self.expires_in: Optional[int] = None
        self.failure: Optional[str] = None

    async def begin(self) -> None:
        from hermes_cli.web_routers import oauth
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
        scope = set_hermes_home_override(self._home)
        try:
            started = await oauth._start_device_code_flow(self.provider, None)
        finally:
            reset_hermes_home_override(scope)
        self._session_id = started["session_id"]
        self.user_code = started["user_code"]
        self.verification_uri = started["verification_url"]
        self.expires_in = int(started["expires_in"])

    async def authorize_url(self) -> Optional[str]:
        return None

    def _session(self) -> Optional[dict]:
        from hermes_cli.web_routers import oauth
        with oauth._oauth_sessions_lock:
            return oauth._oauth_sessions.get(self._session_id)

    async def wait(self) -> bool:
        while True:
            session = self._session()
            status = "cancelled" if session is None or session.get("cancelled") else session["status"]
            if status == "approved":
                return True
            if status != "pending":
                self.failure = self.FAILURES.get(status) or self._error_copy(session)
                return False
            await asyncio.sleep(self.POLL_SECONDS)

    @staticmethod
    def _error_copy(session: Optional[dict]) -> str:
        from agent.redact import redact_sensitive_text
        detail = redact_sensitive_text(str((session or {}).get("error_message") or ""), force=True)[:200]
        return detail or "The provider did not complete the sign-in."

    def cancel(self) -> None:
        from hermes_cli.web_routers import oauth
        with oauth._oauth_sessions_lock:
            session = oauth._oauth_sessions.pop(self._session_id, None)
            if session is not None:
                session["cancelled"] = True


def provider_flow(home: Path, service: str) -> SigninFlow:
    from hermes_cli import model_provider_control as control
    provider = service.partition(":")[2]
    pconfig = control.lookup(provider)
    kind = control.kind_of(pconfig)[0] if pconfig is not None else "unsupported"
    if kind == "api_key":
        return ProviderKeyFlow(provider)
    if kind == "device_code":
        return ProviderDeviceFlow(home, provider)
    return ManualFlow()


register("github", GithubDeviceFlow)
register("mcp", McpServerFlow)
register("connector", HostedConnectorFlow)
register("provider", provider_flow)
