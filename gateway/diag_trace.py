from __future__ import annotations

import functools
import logging
import re
import secrets
import string
import time
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field

from gateway import diag_ledger

TRACE_PATTERN = re.compile(r"[a-z0-9]{1,16}\Z")
REASONS = frozenset({"forbidden", "owner_only", "invalid_params", "not_implemented", "not_found", "timeout",
                     "internal"})
_ALPHABET = string.ascii_lowercase + string.digits
_CODE_REASONS = {-32600: "invalid_params", -32602: "invalid_params", -32601: "not_implemented",
                 4000: "invalid_params", 4001: "invalid_params", 4403: "forbidden", 4404: "not_found",
                 4501: "not_implemented", 4080: "timeout", 5040: "timeout"}

current_trace: ContextVar[str | None] = ContextVar("current_trace", default=None)


def new_trace() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(8))


def is_trace(value) -> bool:
    return isinstance(value, str) and TRACE_PATTERN.match(value) is not None


def reason_for(code) -> str:
    return _CODE_REASONS.get(code, "internal")


@functools.cache
def gateway_version() -> str:
    try:
        from hermes_cli.version_info import get_version_info
        info = get_version_info()
    except Exception:  # health: allow BLE001 -- a version probe never fails a request
        return ""
    return str(info.commit or "")[:8] or str(info.display_version or "")


class TraceLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        trace = current_trace.get()
        if trace and getattr(record, "trace", None) is None:
            record.trace = trace
            record.msg = f"trace={trace} {record.msg}"
        return True


_FILTER = TraceLogFilter()


def install_log_filter() -> None:
    for handler in logging.getLogger().handlers:
        if _FILTER not in handler.filters:
            handler.addFilter(_FILTER)


def _device(transport) -> tuple[str, str, str]:
    from gateway.reach_presence import slot_of
    slot = slot_of(transport) if transport is not None else None
    if slot is None:
        return "", "", ""
    device = slot.device
    return device.kind.value, device.label, device.app_version


@dataclass
class Trace:
    id: str
    outer: bool
    recorded: bool = field(default=False)

    def settle(self, response, frame, *, transport=None, scope: str = "", final: bool = False):
        if not isinstance(response, dict):
            return response
        response["trace"] = self.id
        error = response.get("error")
        if not isinstance(error, dict):
            return response
        data = error.get("data")
        if data is None:
            data = error["data"] = {}
        if isinstance(data, dict):
            data.setdefault("reason", reason_for(error.get("code")))
            data["trace"] = self.id
            data.setdefault("gateway_version", gateway_version())
        if (self.outer or final) and not self.recorded:
            code = error.get("code")
            reason = data.get("reason") if isinstance(data, dict) else None
            self.write(frame, code=code if isinstance(code, int) else None,
                       reason=reason if isinstance(reason, str) else reason_for(code),
                       transport=transport, scope=scope)
        return response

    def fail(self, frame, *, transport=None, scope: str = "") -> None:
        if self.outer and not self.recorded:
            self.write(frame, code=None, reason="internal", transport=transport, scope=scope)

    def write(self, frame, *, code, reason, transport, scope, source="gateway", method=None) -> None:
        self.recorded = True
        kind, name, build = _device(transport)
        frame = frame if isinstance(frame, dict) else {}
        if method is None:
            method = frame.get("method") if isinstance(frame.get("method"), str) else ""
        diag_ledger.record(diag_ledger.Fault(
            ts=time.time(), trace=self.id, method=method[:128], code=code, reason=reason[:64],
            device_kind=kind, device_name=name[:128], app_build=build[:64], gateway_version=gateway_version(),
            params_shape=diag_ledger.params_shape(frame.get("params")), scope=scope, source=source))


@contextmanager
def bound(frame):
    current = current_trace.get()
    if current is not None:
        yield Trace(current, outer=False)
        return
    sent = frame.get("trace") if isinstance(frame, dict) else None
    trace = Trace(sent if is_trace(sent) else new_trace(), outer=True)
    install_log_filter()
    token = current_trace.set(trace.id)
    try:
        yield trace
    finally:
        current_trace.reset(token)
