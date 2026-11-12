"""Effective guard limits of the running gateway (``methods_guards.py``)."""

from __future__ import annotations

from typing import Literal

from .base import Result
from .registry import method
from .base import Params


class GuardValue(Result):
    key: str
    value: bool | int | float
    source: Literal["config", "default"]
    clamped: bool


class GuardsStatus(Result):
    guards: list[GuardValue]


method("gateway.guards.status", params=Params, result=GuardsStatus,
       doc="The bot loop guard limits the gateway enforces now, one entry per gateway.bot_loop_guard key: the "
           "effective value, whether it came from config or the default, and whether the hard limit in code "
           "clamped it. Read-only; reads the live config, so an edit shows without a restart. 4403 secondary profile.")
