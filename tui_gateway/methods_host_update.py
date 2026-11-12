"""``host.update.check``, ``host.update.apply`` and ``host.update.status``: update Pal's host from the app.

Owner-only like the other host methods: a connection bound to a secondary profile's ticket is refused, since
the install is the host user's and shared by every profile. Not a model tool, and bot sessions have no RPC
channel. Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_UPDATE_FORBIDDEN = 4403
_UPDATE_FAILED = 5321


def _update_owner_only(rid, action):
    from tui_gateway import host_update
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _UPDATE_FORBIDDEN, "Only the owner can update Pal")
    try:
        return _ok(rid, action(host_update))
    except Exception:
        logger.exception("host update RPC failed")
        return _err(rid, _UPDATE_FAILED, "Couldn't read the update state on this computer.")


@method("host.update.check")
def _(rid, params: dict) -> dict:
    return _update_owner_only(rid, lambda update: update.check())


@method("host.update.apply")
def _(rid, params: dict) -> dict:
    return _update_owner_only(rid, lambda update: update.apply(confirm_turns=bool(params.get("confirm_turns"))))


@method("host.update.status")
def _(rid, params: dict) -> dict:
    return _update_owner_only(rid, lambda update: update.status())


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
