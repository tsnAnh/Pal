from __future__ import annotations

from .base import Params, Result, WireEnum
from .common import ProfileParams
from .registry import method


class GatewayServiceState(WireEnum):
    running = "running"
    stopped = "stopped"
    not_installed = "not_installed"
    restart_needed = "restart_needed"
    unsupported = "unsupported"


class GatewayServiceStatus(Result):
    """The gateway service on the connected host. ``instance`` changes on every restart (proof the new
    gateway is up); ``started_at`` is epoch seconds when the host can tell. ``active_runs`` counts chats and
    runs a restart would interrupt. No path, token or environment value is carried."""

    backend: str
    state: GatewayServiceState
    installed: bool
    running: bool
    restart_needed: bool
    active_runs: int
    instance: str | None = None
    started_at: float | None = None
    reason: str | None = None


method("gateway.service.status", params=ProfileParams, result=GatewayServiceStatus,
       doc="Gateway service state on the connected host (running, stopped, not installed, restart needed).")


class GatewayServiceRestartParams(ProfileParams):
    """``force`` interrupts running chats; only the host's main connection may set it."""

    force: bool | None = None


class GatewayServiceRestartOutcome(WireEnum):
    started = "started"
    busy = "busy"
    refused = "refused"
    unsupported = "unsupported"
    not_installed = "not_installed"
    failed = "failed"


class GatewayServiceRestartResult(Result):
    """``started`` means the supervisor was asked; the caller polls ``gateway.service.status`` until
    ``instance`` differs from ``status.instance`` (the connection drops while the gateway restarts)."""

    outcome: GatewayServiceRestartOutcome
    reason: str | None = None
    status: GatewayServiceStatus


method("gateway.service.restart", params=GatewayServiceRestartParams, result=GatewayServiceRestartResult,
       doc="Ask the host's service manager to restart the gateway; refused while a chat is running.")


class GatewayServiceInstallOutcome(WireEnum):
    installed = "installed"
    already_installed = "already_installed"
    unsupported = "unsupported"
    failed = "failed"


class GatewayServiceInstallResult(Result):
    outcome: GatewayServiceInstallOutcome
    reason: str | None = None
    status: GatewayServiceStatus


method("gateway.service.install", params=ProfileParams, result=GatewayServiceInstallResult,
       doc="Install the gateway as a login service where the host supports one.")
