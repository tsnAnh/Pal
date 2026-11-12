"""Host health and log tail (``methods_host.py``).

Host-level and owner-only: the machine runs every bot, so there is no ``profile`` param. A field that
could not be read degrades to null; no result carries a secret, a credential path or an environment value.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result, WireEnum
from .registry import method


class HostProblem(Result):
    severity: Literal["warning", "error"]
    message: str


class HostHealth(Result):
    """``doctor_ran`` is false when the doctor could not run (``problems`` is then empty and the app must not
    read it as healthy). ``disk_free_bytes`` is for the volume holding Pal's data."""

    version: str | None = None
    commit: str | None = None
    python_version: str | None = None
    platform: str | None = None
    disk_free_bytes: int | None = None
    disk_total_bytes: int | None = None
    host_uptime_seconds: int | None = None
    profile_count: int | None = None
    running_gateway_count: int | None = None
    doctor_ran: bool
    problems: list[HostProblem]


class HostLogName(WireEnum):
    gateway = "gateway"
    agent = "agent"
    errors = "errors"


class HostLogsTailParams(Params):
    """``skip`` is how many of the newest lines to leave out, so the next older page is
    ``skip = skip + len(lines)``."""

    name: HostLogName = HostLogName.gateway
    lines: int = Field(default=200, ge=1, le=500)
    skip: int = Field(default=0, ge=0, le=100000)


class HostLogsTail(Result):
    """Newest line last, token-shaped text already replaced. ``available`` is false when the log file does
    not exist yet. ``truncated`` means older lines were dropped to fit the byte cap."""

    name: HostLogName
    lines: list[str]
    has_more: bool
    truncated: bool
    available: bool


method("host.health", params=Params, result=HostHealth,
       doc="Read-only health of the computer running Pal: version, runtime, free disk, uptime, profile counts and "
           "the doctor's plain-words problems. Owner only (4403 secondary profile); not a model tool.")
method("host.logs.tail", params=HostLogsTailParams, result=HostLogsTail,
       doc="Last lines of one allow-listed Pal log (gateway, agent or errors), newest last, bounded by line and "
           "byte caps, with token-shaped text redacted before it leaves the host. Owner only (4403 secondary "
           "profile); not a model tool.")
