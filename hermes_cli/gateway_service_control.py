"""Gateway service state and actions for clients that cannot run the CLI (the Pal apps).

Restart is spawned detached (``hermes gateway restart`` asks systemd/launchd); the caller polls
``snapshot`` until ``instance`` changes. Nothing here prints, and nothing secret leaves it."""

from __future__ import annotations

import contextlib
import io
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Protocol

logger = logging.getLogger(__name__)

NO_MANAGER_REASON = "This computer has no service manager Hermes can use. Start Hermes where it runs."
FORCE_OWNER_REASON = "Only the main connection to this computer can interrupt running chats."


class ServiceHost(Protocol):
    def backend(self) -> str: ...
    def installed(self) -> bool: ...
    def running(self) -> bool: ...
    def identity(self) -> Optional[dict[str, Any]]: ...
    def active_runs(self) -> int: ...
    def install(self) -> bool: ...
    def spawn_restart(self, profile: Optional[str], interrupt: bool) -> None: ...


@dataclass(frozen=True)
class Snapshot:
    backend: str
    state: str
    installed: bool
    running: bool
    restart_needed: bool
    active_runs: int
    instance: Optional[str]
    started_at: Optional[float]
    reason: Optional[str]

    def wire(self) -> dict[str, Any]:
        return dict(self.__dict__)


class HostServiceControl:
    def backend(self) -> str:
        from hermes_cli import gateway as gw
        from hermes_constants import is_container

        if is_container():
            return "none"
        if gw.supports_systemd_services():
            return "systemd"
        if gw.is_macos():
            return "launchd"
        return "windows" if gw.is_windows() else "none"

    def installed(self) -> bool:
        from hermes_cli import gateway as gw
        return gw._is_service_installed()

    def running(self) -> bool:
        from hermes_cli import gateway as gw
        return gw._is_service_running()

    def identity(self) -> Optional[dict[str, Any]]:
        from gateway.status import get_runtime_status_running_pid, read_runtime_status

        record = read_runtime_status()
        pid = get_runtime_status_running_pid(record) if record else None
        if pid is None:
            return None
        started_at = None
        with contextlib.suppress(Exception):
            import psutil
            started_at = float(psutil.Process(pid).create_time())
        stale = bool(record.get("restart_requested"))
        if not stale and record.get("code_sha"):
            from hermes_cli.version_info import get_code_identity
            current = get_code_identity().get("sha")
            stale = bool(current) and current != record["code_sha"]
        return {"instance": f"{pid}-{record.get('start_time')}", "started_at": started_at, "code_stale": stale}

    def active_runs(self) -> int:
        from hermes_cli.gateway_lifecycle_guards import _candidate_homes, live_work

        for home in _candidate_homes():
            work = live_work(Path(home))
            if work is not None:
                units = [u for u in work.get("active_work") or [] if isinstance(u, dict)]
                return max(len(units), int(work.get("active_agents") or 0))
        return 0

    def install(self) -> bool:
        from hermes_cli.gateway_setup_service import ensure_gateway_service

        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            ok = ensure_gateway_service("setup", install=True)
        logger.debug("gateway service install output: %s", captured.getvalue())
        return ok

    def spawn_restart(self, profile: Optional[str], interrupt: bool) -> None:
        from hermes_cli.web_server import _spawn_gateway_restart
        _spawn_gateway_restart(profile, interrupt=interrupt)


def snapshot(host: ServiceHost) -> Snapshot:
    backend = host.backend()
    installed, running = host.installed(), host.running()
    identity = host.identity() if running else None
    restart_needed = bool(identity and identity.get("code_stale"))
    if backend == "none" and not running:
        state, reason = "unsupported", NO_MANAGER_REASON
    elif running:
        state, reason = ("restart_needed" if restart_needed else "running"), None
    elif installed:
        state, reason = "stopped", None
    else:
        state, reason = "not_installed", None
    return Snapshot(
        backend=backend, state=state, installed=installed, running=running, restart_needed=restart_needed,
        active_runs=host.active_runs() if running else 0,
        instance=identity["instance"] if identity else None,
        started_at=identity.get("started_at") if identity else None, reason=reason)


def restart(host: ServiceHost, profile: Optional[str], *, force: bool, owner: bool) -> dict[str, Any]:
    """``outcome``: started | busy | refused | unsupported | not_installed | failed."""
    before = snapshot(host)
    if before.state == "unsupported":
        return {"outcome": "unsupported", "reason": before.reason, "status": before.wire()}
    if before.state == "not_installed":
        return {"outcome": "not_installed", "reason": "Hermes isn't installed as a service on this computer yet.",
                "status": before.wire()}
    if force and not owner:
        return {"outcome": "refused", "reason": FORCE_OWNER_REASON, "status": before.wire()}
    if before.active_runs and not force:
        plural = "chats are" if before.active_runs > 1 else "a chat is"
        return {"outcome": "busy", "reason": f"Hermes can't restart while {plural} running.",
                "status": before.wire()}
    try:
        host.spawn_restart(profile, force)
    except Exception:
        logger.exception("gateway service restart could not be started")
        return {"outcome": "failed", "reason": "Hermes couldn't start the restart.", "status": before.wire()}
    return {"outcome": "started", "reason": None, "status": before.wire()}


def install(host: ServiceHost) -> dict[str, Any]:
    """``outcome``: installed | already_installed | unsupported | failed."""
    before = snapshot(host)
    if before.state == "unsupported":
        return {"outcome": "unsupported", "reason": before.reason, "status": before.wire()}
    if before.installed:
        return {"outcome": "already_installed", "reason": None, "status": before.wire()}
    try:
        ok = host.install()
    except Exception:
        logger.exception("gateway service install failed")
        ok = False
    after = snapshot(host)
    if ok and after.installed:
        return {"outcome": "installed", "reason": None, "status": after.wire()}
    return {"outcome": "failed", "reason": "Hermes couldn't install the service on this computer.",
            "status": after.wire()}
