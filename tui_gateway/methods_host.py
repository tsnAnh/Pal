"""``host.health`` and ``host.logs.tail``: read-only views of the computer running Pal, for the app's Server screen.

Owner-only like the github.* methods: a connection bound to a secondary profile's ticket is refused. Neither is
a model tool, and bot sessions have no RPC channel. Fixed commands only; nothing from the client reaches an
argv or a path. Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_HOST_FORBIDDEN = 4403
_HOST_FAILED = 5401


def _host_owner_only(rid, action, failure):
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _HOST_FORBIDDEN, "Only the owner can see this computer's health and logs")
    try:
        return _ok(rid, action())
    except Exception:
        logger.exception("host RPC failed")
        return _err(rid, _HOST_FAILED, failure)


@method("host.health")
def _(rid, params: dict) -> dict:
    from tui_gateway import host_health
    return _host_owner_only(rid, host_health.collect, "Couldn't read this computer's health")


@method("host.logs.tail")
def _(rid, params: dict) -> dict:
    from tui_gateway import host_logs

    def read():
        name = params.get("name", "gateway")
        result = host_logs.tail(name, params.get("lines", 200), params.get("skip", 0))
        return {"name": name, "lines": result.lines, "has_more": result.has_more,
                "truncated": result.truncated, "available": result.available}

    return _host_owner_only(rid, read, "Couldn't read that log")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
