"""``speech_memory.settings.get/set``: the bot's text-to-speech and memory providers for the Pal apps. Keys are
set and removed with ``capabilities.set_key``; nothing here reads a key value, only whether one is set.
Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_SPEECH_MEMORY_FAILED = 5104


def _speech_memory_snapshot(params: dict) -> dict:
    from tui_gateway import speech_memory_settings
    return speech_memory_settings.snapshot(_bot_settings_profile_name(params))


@method("speech_memory.settings.get")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        return _ok(rid, _speech_memory_snapshot(params))
    except Exception:
        logger.exception("speech_memory.settings.get failed")
        return _err(rid, _SPEECH_MEMORY_FAILED, "Could not read the voice and memory settings")


@method("speech_memory.settings.set")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tui_gateway import speech_memory_settings
    area, provider, voice = params.get("area"), params.get("provider"), params.get("voice")
    if area not in ("tts", "memory") or not isinstance(provider, str):
        return _err(rid, 4101, "That choice is not valid")
    try:
        outcome, reason = speech_memory_settings.apply_choice(area, provider, voice)
        settings = _speech_memory_snapshot(params)
    except Exception:
        logger.exception("speech_memory.settings.set failed for %s", area)
        return _ok(rid, {"outcome": "failed", "reason": "Could not save that choice. Nothing was changed."})
    return _ok(rid, {"outcome": outcome, "reason": reason, "settings": settings})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
