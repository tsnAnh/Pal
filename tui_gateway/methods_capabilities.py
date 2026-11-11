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
_CAPABILITY_KEY_INVALID = 4101


def _status_result(rid, params: dict, key_name=None, is_set=None) -> dict:
    from tui_gateway.capabilities_status import capability_rows
    body = {"profile": _bot_settings_profile_name(params),
            "capabilities": [row.model_dump(mode="json") for row in capability_rows()]}
    return _ok(rid, body if key_name is None else {**body, "key_name": key_name, "is_set": is_set})


@method("capabilities.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        return _status_result(rid, params)
    except Exception:
        logger.exception("capabilities.status failed")
        return _err(rid, _CAPABILITIES_FAILED, "Could not read the capability status")


@method("capabilities.set_key")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from gateway.auth_flows import credential_text
    from hermes_cli.credential_lifecycle import remove_provider_env_credential
    from hermes_cli.config import save_env_value_secure
    from tui_gateway.capabilities_status import SETTABLE_KEYS
    key_name, raw = params.get("key_name"), params.get("value")
    if key_name not in SETTABLE_KEYS:
        return _err(rid, _CAPABILITY_KEY_INVALID, "That key cannot be set here")
    text = None if raw is None else credential_text(raw)
    if raw is not None and text is None:
        return _err(rid, _CAPABILITY_KEY_INVALID, "That value is not a valid key")
    try:
        if text is None:
            remove_provider_env_credential(key_name)
        else:
            save_env_value_secure(key_name, text)
        return _status_result(rid, params, key_name, text is not None)
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        logger.warning("capabilities.set_key could not save %s (%s)", key_name, type(exc).__name__)
        return _err(rid, _CAPABILITIES_FAILED, "Could not save the key")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
