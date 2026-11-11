from __future__ import annotations

TTS_KEYS = ("ELEVENLABS_API_KEY", "VOICE_TOOLS_OPENAI_KEY", "XAI_API_KEY", "MINIMAX_API_KEY", "MISTRAL_API_KEY",
            "GEMINI_API_KEY")
MEMORY_KEYS = ("RETAINDB_API_KEY", "BRV_API_KEY")

_DEFAULT_TTS = "edge"
_XAI = (("XAI_API_KEY",), "XAI_API_KEY")
_TTS_NOTES = {
    "openai": "Also uses your OpenAI model key when this one is not set.",
    "gemini": "Also uses your Google model key when this one is not set.",
    "xai": "Also works with an xAI sign-in from Model providers.",
}


def _key_set(names) -> bool:
    from hermes_cli.config import get_env_value
    return any((get_env_value(name) or "").strip() for name in names)


def _in_env_file(name: str) -> bool:
    from hermes_cli.config import load_env
    return bool((load_env().get(name) or "").strip())


def _tts_key_table() -> dict[str, tuple[tuple[str, ...], str]]:
    from hermes_cli.setup_tts import _TTS_API_KEY_PROVIDERS
    table = {pid: (env_vars, save_var) for pid, (env_vars, save_var, *_rest) in _TTS_API_KEY_PROVIDERS.items()}
    return {**table, "xai": _XAI}


def _tts_row(pid: str, name: str, keys: dict) -> dict:
    row = {"id": pid, "name": name, "ready": True}
    if pid not in keys:
        return row
    env_vars, save_var = keys[pid]
    is_set = _key_set(env_vars)
    return {**row, "key_name": save_var, "key_required": True, "key_set": is_set, "ready": is_set,
            "can_remove": _in_env_file(save_var), "note": _TTS_NOTES.get(pid)}


def _tts_providers() -> list[dict]:
    from hermes_cli import setup as setup_module
    from hermes_cli.setup_tts import _TTS_LOCAL_PROVIDERS, _TTS_PROVIDER_CHOICES, _TTS_PROVIDER_LABELS
    keys = _tts_key_table()
    rows = []
    for pid, _label in _TTS_PROVIDER_CHOICES:
        local = _TTS_LOCAL_PROVIDERS.get(pid)
        if local is not None and not setup_module._module_installed(local[0]):
            continue
        rows.append(_tts_row(pid, _TTS_PROVIDER_LABELS[pid], keys))
    return rows


def _edge_voice(config: dict) -> dict:
    from hermes_cli.setup_tts import _EDGE_VOICE_CHOICES
    tts = config.get("tts") if isinstance(config.get("tts"), dict) else {}
    edge = tts.get("edge") if isinstance(tts.get("edge"), dict) else {}
    current = str(edge.get("voice") or "en-US-AriaNeural")
    options = [{"id": voice, "label": label} for voice, label in _EDGE_VOICE_CHOICES]
    if current not in {option["id"] for option in options}:
        options.insert(0, {"id": current, "label": current})
    return {"current": current, "options": options}


def _tts_selected(config: dict) -> str:
    tts = config.get("tts") if isinstance(config.get("tts"), dict) else {}
    return str(tts.get("provider") or _DEFAULT_TTS)


def _memory_key_field(provider) -> dict | None:
    schema = provider.get_config_schema() if hasattr(provider, "get_config_schema") else []
    return next((f for f in schema if f.get("secret") and f.get("env_var") in MEMORY_KEYS), None)


def _memory_providers() -> list[dict]:
    from plugins.memory import discover_memory_providers, load_memory_provider
    rows = []
    for name, description, available in discover_memory_providers():
        provider = load_memory_provider(name)
        if provider is None:
            continue
        field = _memory_key_field(provider)
        owns_setup = hasattr(provider, "post_setup")
        row = {"id": name, "name": name, "description": description or None, "ready": bool(available),
               "selectable": not owns_setup}
        if field is not None:
            env_var = field["env_var"]
            row |= {"key_name": env_var, "key_required": bool(field.get("required")), "key_set": _key_set([env_var]),
                    "can_remove": _in_env_file(env_var)}
        rows.append(row)
    return rows


def _memory_selected(config: dict) -> str:
    memory = config.get("memory") if isinstance(config.get("memory"), dict) else {}
    return str(memory.get("provider") or "")


def snapshot(profile: str) -> dict:
    from hermes_cli.config import load_config
    config = load_config()
    selected = _tts_selected(config)
    return {
        "profile": profile,
        "tts": {"selected": selected, "providers": _tts_providers(),
                "voice": _edge_voice(config) if selected == _DEFAULT_TTS else None},
        "memory": {"selected": _memory_selected(config), "providers": _memory_providers()}}


def _choose(rows: list[dict], provider: str, allow_empty: bool):
    if allow_empty and provider == "":
        return {"id": ""}
    return next((row for row in rows if row["id"] == provider), None)


def _refusal(row: dict | None):
    if row is None:
        return "unsupported", "That provider isn't available on this computer."
    if row.get("selectable") is False:
        return "unsupported", "That provider needs a setup this app can't do yet."
    if row.get("key_required") and not row.get("key_set"):
        return "needs_key", "Add its key first."
    return None


def apply_choice(area: str, provider: str, voice: str | None) -> tuple[str, str | None]:
    from hermes_cli.config import load_config, save_config
    provider = provider.strip()
    config = load_config()
    if area == "tts":
        row = _choose(_tts_providers(), provider, allow_empty=False)
        refused = _refusal(row)
        if refused:
            return refused
        if voice is not None:
            options = {option["id"] for option in _edge_voice(config)["options"]}
            if provider != _DEFAULT_TTS or voice not in options:
                return "invalid", "That voice isn't available."
            config.setdefault("tts", {}).setdefault("edge", {})["voice"] = voice
        config.setdefault("tts", {})["provider"] = provider
    else:
        refused = _refusal(_choose(_memory_providers(), provider, allow_empty=True))
        if refused:
            return refused
        if not isinstance(config.get("memory"), dict):
            config["memory"] = {}
        config["memory"]["provider"] = provider
    save_config(config)
    return "saved", None
