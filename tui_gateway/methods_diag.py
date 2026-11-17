"""``diag.recent`` and ``diag.report``: read and add to the gateway's failure ledger. Owner connections only.
Bodies are rebound onto server.py's globals (method_ctx.bind_module)."""

import logging
import sqlite3

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_DIAG_OWNER_ONLY = 4403


def _diag_refusal(rid):
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _DIAG_OWNER_ONLY, "Only the owner can read failures", data={"reason": "owner_only"})
    return None


@method("diag.recent")
def _(rid, params: dict) -> dict:
    if refusal := _diag_refusal(rid):
        return refusal
    from gateway import diag_ledger
    minutes = min(max(int(params.get("minutes", 10)), 1), 10080)
    limit = min(max(int(params.get("limit", 50)), 1), 200)
    try:
        faults = diag_ledger.recent(minutes=minutes, limit=limit, method=params.get("method") or None)
    except (sqlite3.Error, OSError) as exc:
        logger.warning("could not read the failure ledger (%s)", type(exc).__name__)
        return _err(rid, 5001, "storage_unavailable", data={"reason": "internal"})
    return _ok(rid, {"faults": faults})


@method("diag.report")
def _(rid, params: dict) -> dict:
    if refusal := _diag_refusal(rid):
        return refusal
    from gateway import diag_trace
    if params["method"] not in _contracts.METHODS and params["method"] not in _contracts.CANONICAL_METHODS:
        return _err(rid, 4000, "invalid params: method", data={"reason": "invalid_params", "field": "method"})
    diag_trace.Trace(params["trace"], outer=False).write(
        {}, code=params.get("code"), reason=params["reason"], transport=current_transport(), scope="",
        source=params["source"], method=params["method"])
    return _ok(rid, {"recorded": True})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
