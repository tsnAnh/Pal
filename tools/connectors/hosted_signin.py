from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Optional

from gateway import auth_flows


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


def register() -> None:
    auth_flows.register("connector", HostedConnectorFlow)
