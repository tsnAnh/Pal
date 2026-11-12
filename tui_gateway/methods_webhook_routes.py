"""``webhook.routes.*``: the owner's webhook routes and a two-hop reachability probe, from the app.

Owner-only: a connection bound to a secondary profile's ticket is refused. Not a model tool, and bot sessions
have no RPC channel. Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_WEBHOOK_FORBIDDEN = 4403
_WEBHOOK_INVALID = 4101
_WEBHOOK_NOT_FOUND = 4404
_WEBHOOK_EXISTS = 4409
_WEBHOOK_FAILED = 5321
_CODE_TO_ERROR = {"not_found": _WEBHOOK_NOT_FOUND, "exists": _WEBHOOK_EXISTS}


def _owner_only(rid, action):
    from tui_gateway import webhook_routes
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _WEBHOOK_FORBIDDEN, "Only the owner can manage webhook routes")
    try:
        return _ok(rid, action(webhook_routes))
    except webhook_routes.RouteError as exc:
        if exc.code == "webhook_disabled":
            return _err(rid, _WEBHOOK_FAILED, exc.message, {"code": exc.code})
        return _err(rid, _CODE_TO_ERROR.get(exc.code, _WEBHOOK_INVALID), exc.message, {"code": exc.code})
    except Exception:
        logger.exception("webhook routes RPC failed")
        return _err(rid, _WEBHOOK_FAILED, "Couldn't change webhook routes on this computer.", {"code": "failed"})


@method("webhook.routes.list")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda routes: routes.list_routes())


@method("webhook.routes.add")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda routes: routes.add_route(params))


@method("webhook.routes.remove")
def _(rid, params: dict) -> dict:
    def remove(routes):
        routes.remove_route(str(params.get("name") or ""))
        return {"ok": True}
    return _owner_only(rid, remove)


@method("webhook.routes.probe")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda routes: routes.probe_route(str(params.get("name") or "")))


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
