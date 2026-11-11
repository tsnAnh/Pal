"""``capabilities.status``: read-only list of the five bot capabilities and why each is on or off, from the
named bot's own config.yaml and .env. Rows come from ``tui_gateway/capabilities_status.py``; no key value
is ever read into the result, only whether a key name is set.
Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_CAPABILITIES_FAILED = 5103


@method("capabilities.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway.capabilities_status import capability_rows
    try:
        rows = capability_rows()
    except Exception:
        logger.exception("capabilities.status failed")
        return _err(rid, _CAPABILITIES_FAILED, "Could not read the capability status")
    return _ok(rid, {"profile": _bot_settings_profile_name(params),
                     "capabilities": [row.model_dump(mode="json") for row in rows]})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
