"""``bot_keys.status`` and ``bot_keys.set``: the extra tool, memory, app and messaging keys the app sets by name.

Owner connections only: a connection bound to a bot's own ticket is refused. Not a model tool, and bot
sessions have no RPC channel. The value goes to the named bot's .env through the same writer as
capabilities.set_key and appears in no result or log.
Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_BOT_KEYS_FORBIDDEN = 4403
_BOT_KEYS_INVALID = 4101
_BOT_KEYS_FAILED = 5103


def _owner_connection_refusal(rid):
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _BOT_KEYS_FORBIDDEN, "Only the owner can manage a bot's keys")
    return None


def _bot_keys_body(params: dict, **extra) -> dict:
    from tui_gateway.bot_keys import key_groups
    return {"profile": _bot_settings_profile_name(params),
            "groups": [group.model_dump(mode="json") for group in key_groups()], **extra}


@method("bot_keys.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    if refusal := _owner_connection_refusal(rid):
        return refusal
    try:
        return _ok(rid, _bot_keys_body(params))
    except Exception:
        logger.exception("bot_keys.status failed")
        return _err(rid, _BOT_KEYS_FAILED, "Could not read the keys")


@method("bot_keys.set")
@_profile_scoped
def _(rid, params: dict) -> dict:
    if refusal := _owner_connection_refusal(rid):
        return refusal
    from gateway.auth_flows import credential_text
    from hermes_cli.credential_lifecycle import remove_provider_env_credential
    from hermes_cli.config import save_env_value_secure
    from tui_gateway.bot_keys import SETTABLE_KEYS
    key_name, raw = params.get("key_name"), params.get("value")
    if key_name not in SETTABLE_KEYS:
        return _err(rid, _BOT_KEYS_INVALID, "That key cannot be set here")
    text = None if raw is None else credential_text(raw)
    if raw is not None and text is None:
        return _err(rid, _BOT_KEYS_INVALID, "That value is not a valid key")
    try:
        if text is None:
            remove_provider_env_credential(key_name)
        else:
            save_env_value_secure(key_name, text)
        return _ok(rid, _bot_keys_body(params, key_name=key_name, is_set=text is not None))
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        logger.warning("bot_keys.set could not save %s (%s)", key_name, type(exc).__name__)
        return _err(rid, _BOT_KEYS_FAILED, "Could not save the key")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
