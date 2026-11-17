"""``diag.recent`` and ``diag.report``: the gateway's failure ledger (``gateway/diag_ledger.py``).

Owner-only. A row holds codes, the trace id, the calling device and the param key names with their
value types; never a param value, a token or provider text.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result
from .registry import method

TracePattern = r"^[a-z0-9]{1,16}$"
FaultReason = Literal["forbidden", "owner_only", "invalid_params", "not_implemented", "not_found", "timeout",
                      "internal", "decode", "offline"]


class DiagRecentParams(Params):
    minutes: int = 10
    limit: int = 50
    method: str | None = Field(default=None, max_length=128)


class DiagFault(Result):
    ts: float
    trace: str
    method: str
    code: int | None = None
    reason: str
    device_kind: str
    device_name: str
    app_build: str
    gateway_version: str
    params_shape: str
    scope: str
    source: str


class DiagRecentResult(Result):
    faults: list[DiagFault]


class DiagReportParams(Params):
    trace: str = Field(pattern=TracePattern)
    source: Literal["transport", "decode"]
    reason: FaultReason
    method: str = Field(min_length=1, max_length=128)
    code: int | None = None


class DiagReportResult(Result):
    recorded: bool


method("diag.recent", params=DiagRecentParams, result=DiagRecentResult,
       doc="Recent failed RPCs from the gateway's failure ledger, newest first: method, code, reason, device, app "
           "build, gateway version, trace and time. minutes is clamped to 1..10080 and limit to 1..200. Owner only.")
method("diag.report", params=DiagReportParams, result=DiagReportResult,
       doc="Record a failure the gateway could not see (transport: offline or timed out; decode: an unreadable "
           "response) under the app's trace id, with the calling device. method must be a registered method. "
           "Owner only.")
