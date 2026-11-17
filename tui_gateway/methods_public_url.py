"""``webapp.public_url.*``: the owner sets and checks the gateway's public https address from the apps.

Owner-only: a connection bound to a secondary profile's ticket is refused. Bodies are rebound onto server.py's
globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_OWNER_ONLY = 4403
_FORBIDDEN = 4030
_INVALID = 4000
_FAILED = 5001


def _owner_refusal(rid):
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _OWNER_ONLY, "Only the owner can change the public address", data={"reason": "owner_only"})
    return None


def _home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def _state(rid):
    from gateway import public_address
    state = public_address.read(_home())
    return _ok(rid, {"url": state.url, "routes_enabled": state.routes_enabled, "suggestion": state.suggestion})


@method("webapp.public_url.get")
def _(rid, params: dict) -> dict:
    return _owner_refusal(rid) or _state(rid)


@method("webapp.public_url.set")
def _(rid, params: dict) -> dict:
    if refusal := _owner_refusal(rid):
        return refusal
    from gateway import public_address
    try:
        public_address.save(_home(), str(params.get("url", "")))
    except public_address.AddressError as exc:
        return _err(rid, _INVALID, "invalid params: url",
                    data={"reason": "invalid_params", "field": "url", "problem": exc.problem.value})
    except public_address.ManagedAddressError:
        return _err(rid, _FORBIDDEN, "The public address is managed by your administrator",
                    data={"reason": "forbidden"})
    except OSError:
        logger.warning("could not save the public address")
        return _err(rid, _FAILED, "Couldn't save the public address", data={"reason": "internal"})
    return _state(rid)


@method("webapp.public_url.check")
def _(rid, params: dict) -> dict:
    if refusal := _owner_refusal(rid):
        return refusal
    from gateway import public_address
    url = public_address.read(_home(), suggest=lambda: None).url
    outcome = public_address.check(url)
    return _ok(rid, {"outcome": outcome.value, "url": url})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
