import logging
import re

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_SETTINGS_INVALID = 4101
_SETTINGS_NOT_FOUND = 4103
_SETTINGS_FAILED = 5102
_SETTINGS_MAX_IDS = 200
_SETTINGS_PORT_KEY = "WEBHOOK_PORT"
_SETTINGS_ALLOWLIST_KEY = re.compile(r"_ALLOWED(?:_[A-Z]+)?$")
_SETTINGS_GENERIC_ID = re.compile(r"^[A-Za-z0-9_.@+:=!#-]{1,128}$")
_SETTINGS_DIGITS = re.compile(r"^\d{1,20}$")
_SETTINGS_USER_ID_RULES = {
    "telegram": (_SETTINGS_DIGITS, "Telegram user IDs are numbers, like 123456789."),
    "discord": (_SETTINGS_DIGITS, "Discord user IDs are numbers, like 123456789012345678."),
    "slack": (re.compile(r"^[UW][A-Z0-9]{2,31}$"), "Slack member IDs start with U or W, like U01ABC2DEF3."),
}
_SETTINGS_CHANNEL_RULES = {
    "telegram": (re.compile(r"^-?\d{1,20}$"), "Telegram chat IDs are numbers, like 123456789 or -1001234567890."),
    "discord": (_SETTINGS_DIGITS, "Discord channel IDs are numbers, like 123456789012345678."),
    "slack": (re.compile(r"^[CDG][A-Z0-9]{2,31}$"), "Slack channel IDs start with C, D or G, like C01ABC2DEF3."),
}
_SETTINGS_GENERIC_MESSAGE = "Use letters, numbers and . _ @ + : = ! # - only (up to 128 characters)."


def _settings_messaging():
    from hermes_cli.web_routers import messaging
    return messaging


def _settings_kind(key, is_password):
    if is_password:
        return "secret"
    if _SETTINGS_ALLOWLIST_KEY.search(key):
        return "allowlist"
    if key == _SETTINGS_PORT_KEY:
        return "port"
    return None


def _settings_split(raw):
    return [part for part in (piece.strip() for piece in str(raw or "").split(",")) if part]


def _settings_layout(entry):
    messaging = _settings_messaging()
    from gateway.platform_registry import platform_registry
    registered = platform_registry.get(entry["id"])
    home_key = getattr(registered, "cron_deliver_env_var", "") or ""
    fields, secrets = [], []
    for key in dict.fromkeys([*entry["env_vars"], *([home_key] if home_key else [])]):
        info = messaging._messaging_env_info(key)
        kind = "home_channel" if key == home_key else _settings_kind(key, info["is_password"])
        label = "Home channel" if key == home_key else info["prompt"] or key
        if kind == "secret":
            secrets.append({"key": key, "label": label})
        elif kind:
            fields.append({"key": key, "kind": kind, "label": label})
    return fields, secrets


def _settings_platform(entry, env, state):
    fields, secrets = _settings_layout(entry)
    return {
        "id": entry["id"], "name": entry["name"], "enabled": state["enabled"], "configured": state["configured"],
        "state": state["state"], "error_message": state["error_message"],
        "fields": [{**field, "values": _settings_split(env.get(field["key"]))} for field in fields],
        "secrets": [{**secret, "is_set": bool(env.get(secret["key"]))} for secret in secrets]}


def _settings_state(payload):
    return {key: payload[key] for key in ("enabled", "configured", "state", "error_message")}


def _settings_snapshot(params, platform_id=None):
    messaging = _settings_messaging()
    entries = [messaging._require_platform(platform_id)] if platform_id else list(messaging._messaging_platform_catalog())
    home = _profile_home(params.get("profile"))
    payloads = messaging._platform_payloads(home, entries)
    env = messaging.load_env()
    platforms = []
    for entry, payload in zip(entries, payloads):
        platform = _settings_platform(entry, env, _settings_state(payload))
        if platform_id or platform["fields"] or platform["secrets"]:
            platforms.append(platform)
    return payloads[0]["gateway_running"] if payloads else False, platforms


def _settings_check_ids(platform_id, key, kind, values, errors):
    rules = _SETTINGS_USER_ID_RULES if kind == "allowlist" else _SETTINGS_CHANNEL_RULES
    pattern, message = rules.get(platform_id, (_SETTINGS_GENERIC_ID, _SETTINGS_GENERIC_MESSAGE))
    bad = [value for value in values if not pattern.match(value)]
    if bad:
        errors[key] = message


def _settings_check_port(key, values, errors):
    ok = len(values) == 1 and values[0].isdigit() and 1 <= int(values[0]) <= 65535
    if not ok:
        errors[key] = "The port must be a whole number from 1 to 65535."


def _settings_normalise(platform_id, layout, requested):
    kinds = {field["key"]: field["kind"] for field in layout}
    cleaned, errors = {}, {}
    for key, raw in requested.items():
        kind = kinds.get(key)
        if kind is None:
            errors[key] = "This setting cannot be changed here."
            continue
        if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
            errors[key] = "Send a list of values."
            continue
        values = list(dict.fromkeys(item.strip() for item in raw if item.strip()))
        if kind != "allowlist" and len(values) > 1:
            errors[key] = "Only one value is allowed."
        elif len(values) > _SETTINGS_MAX_IDS:
            errors[key] = f"At most {_SETTINGS_MAX_IDS} entries are allowed."
        elif kind == "port" and values:
            _settings_check_port(key, values, errors)
        elif values:
            _settings_check_ids(platform_id, key, kind, values, errors)
        cleaned[key] = ",".join(values)
    return cleaned, errors


def _settings_write(messaging, old_env, changes, enabled):
    written = []
    try:
        for key, value in changes.items():
            written.append(key)
            if value:
                messaging.save_env_value(key, value)
            else:
                messaging.remove_env_value(key)
        if enabled is not None:
            messaging._write_platform_enabled(enabled[0], enabled[1])
    except Exception:
        for key in written:
            previous = old_env.get(key)
            if previous:
                messaging.save_env_value(key, previous)
            else:
                messaging.remove_env_value(key)
        raise


@method("messaging.settings.get")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    try:
        running, platforms = _settings_snapshot(params)
        return _ok(rid, {"profile": _bot_settings_profile_name(params), "gateway_running": running,
                         "platforms": platforms})
    except HTTPException as exc:
        return _err(rid, _SETTINGS_FAILED if exc.status_code >= 500 else _SETTINGS_INVALID, str(exc.detail))
    except Exception:
        logger.exception("messaging.settings.get failed")
        return _err(rid, _SETTINGS_FAILED, "Could not load the messaging settings")


@method("messaging.settings.update")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    platform_id = str(params.get("platform") or "").strip()
    requested = params.get("fields") or {}
    enabled = params.get("enabled")
    if not platform_id or not isinstance(requested, dict) or (enabled is not None and not isinstance(enabled, bool)):
        return _err(rid, _SETTINGS_INVALID, "platform is required; fields must be an object and enabled a boolean")
    messaging = _settings_messaging()
    try:
        entry = messaging._require_platform(platform_id)
    except HTTPException as exc:
        return _err(rid, _SETTINGS_NOT_FOUND, str(exc.detail))
    layout, _ = _settings_layout(entry)
    cleaned, errors = _settings_normalise(platform_id, layout, requested)
    profile_arg = str(params.get("profile") or "").strip() or None
    if enabled:
        conflict = messaging._multiplex_port_binding_conflict(platform_id, profile_arg)
        if conflict:
            errors["enabled"] = conflict
    if errors:
        return _err(rid, _SETTINGS_INVALID, "Some settings need a change before they can be saved.", {"fields": errors})
    try:
        old_env = messaging.load_env()
        _, before = _settings_snapshot(params, platform_id)
        changes = {key: value for key, value in cleaned.items() if value != ",".join(_settings_split(old_env.get(key)))}
        toggle = (platform_id, enabled) if enabled is not None and enabled != before[0]["enabled"] else None
        if changes or toggle:
            _settings_write(messaging, old_env, changes, toggle)
            logger.info("Messaging settings updated: platform=%s profile=%s keys=%s enabled=%s",
                        platform_id, profile_arg or "current", sorted(changes), toggle[1] if toggle else None)
        running, after = _settings_snapshot(params, platform_id)
        changed = bool(changes or toggle)
        hot_served = bool(changed and running and messaging._notify_multiplexer_hot_serve(profile_arg))
        return _ok(rid, {"profile": _bot_settings_profile_name(params), "gateway_running": running,
                         "settings": after[0], "changed": changed, "hot_served": hot_served,
                         "restart_needed": bool(changed and running and not hot_served)})
    except HTTPException as exc:
        return _err(rid, _SETTINGS_FAILED if exc.status_code >= 500 else _SETTINGS_INVALID, str(exc.detail))
    except Exception:
        logger.exception("messaging.settings.update failed")
        return _err(rid, _SETTINGS_FAILED, "Could not save the settings. Nothing was changed.")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
