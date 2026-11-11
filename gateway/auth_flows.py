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


FlowFactory = Callable[[Path, str], SigninFlow]
_factories: dict[str, FlowFactory] = {}


def register(prefix: str, factory: FlowFactory) -> None:
    _factories[prefix] = factory


def unregister(prefix: str) -> None:
    _factories.pop(prefix, None)


def flow_for(home: Path, service: str) -> SigninFlow:
    factory = _factories.get(service) or _factories.get(service.partition(":")[0])
    return factory(home, service) if factory is not None else ManualFlow()


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
            status = mcp_oauth_sessions.poll_flow(self._session_id, self._server).get("status")
            if status == "approved":
                return True
            if status == "error":
                return False
            await asyncio.sleep(self.POLL_SECONDS)
        return False

    def cancel(self) -> None:
        self._cancelled = True
        self._started.set()
        if self._session_id:
            from tui_gateway import mcp_oauth_sessions
            mcp_oauth_sessions.cancel_flow(self._session_id, self._server, self._home_key())


register("github", GithubDeviceFlow)
register("mcp", McpOAuthFlow)
