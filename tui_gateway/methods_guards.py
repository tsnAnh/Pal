"""``gateway.guards.status``: the limits the gateway enforces now, for the Pal apps.

Owner-only like the github.* methods: a connection bound to a secondary profile's ticket is refused. Not a
model tool, and bot sessions have no RPC channel. Bodies are rebound onto server.py's globals
(method_ctx.bind_module) and reference them bare.
"""

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method

_GUARDS_FORBIDDEN = 4403


@method("gateway.guards.status")
def _(rid, params: dict) -> dict:
    from gateway.bot_loop_guard import resolve_config
    from hermes_cli.config import load_config_readonly
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _GUARDS_FORBIDDEN, "Only the owner can read the gateway limits")
    guards = [
        {"key": f"gateway.bot_loop_guard.{item.key}", "value": item.value, "source": item.source, "clamped": item.clamped}
        for item in resolve_config(load_config_readonly()).values()]
    return _ok(rid, {"guards": guards})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
