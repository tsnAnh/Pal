import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_WA_INVALID = 4111
_WA_NOT_FOUND = 4113
_WA_CONFLICT = 4119
_WA_FAILED = 5112
_WA_MAX_FIELD = 1000
_WA_CLOUD_ENV = {
    "phone_number_id": "WHATSAPP_CLOUD_PHONE_NUMBER_ID", "access_token": "WHATSAPP_CLOUD_ACCESS_TOKEN",
    "app_secret": "WHATSAPP_CLOUD_APP_SECRET", "allowed_users": "WHATSAPP_CLOUD_ALLOWED_USERS"}


def _wa_messaging():
    from hermes_cli.web_routers import messaging
    return messaging


def _wa_profile_arg(params):
    return str(params.get("profile") or "").strip() or None


def _wa_http_error(rid, exc):
    detail = str(exc.detail)
    code = {404: _WA_NOT_FOUND, 409: _WA_CONFLICT}.get(exc.status_code)
    if code is None:
        code = _WA_INVALID if exc.status_code < 500 else _WA_FAILED
    return _err(rid, code, detail)


def _wa_run(coro):
    import asyncio
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    import concurrent.futures
    import contextvars
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(contextvars.copy_context().run, asyncio.run, coro).result()


def _wa_text(params, key):
    value = params.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > _WA_MAX_FIELD:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail=f"{key} must be text of at most {_WA_MAX_FIELD} characters")
    return value


def _wa_pairing_view(pairing_id, record):
    waiting = record.status == "waiting"
    return {
        "pairing_id": pairing_id, "status": record.status, "qr_payload": record.qr_payload if waiting else None,
        "expires_at": record.expires_at, "mode": record.mode, "allowed_users": record.allowed_users,
        "account_name": record.account_name, "account_phone": record.account_phone, "error": record.error}


def _wa_owned_record(messaging, params):
    """The pairing, only if it belongs to the requesting bot's own session directory."""
    from fastapi import HTTPException
    pairing_id = str(params.get("pairing_id") or "")
    with messaging._config_profile_scope(_wa_profile_arg(params)), messaging._whatsapp_onboarding_lock:
        messaging._prune_whatsapp_onboarding_sessions()
        record = messaging._whatsapp_onboarding_sessions.get(pairing_id)
        if record is None or record.session_path != str(messaging._whatsapp_session_path()):
            raise HTTPException(status_code=404, detail=messaging._WHATSAPP_SESSION_NOT_FOUND)
    return pairing_id, record


def _wa_status_payload(params):
    from hermes_cli.main_platform_setup import _whatsapp_has_paired_identity
    messaging = _wa_messaging()
    profile_dir = _profile_home(params.get("profile"))
    with messaging._config_profile_scope(_wa_profile_arg(params)):
        entry = messaging._require_platform("whatsapp")
        payload = messaging._platform_payloads(Path(profile_dir) if profile_dir else None, [entry])[0]
        env = messaging.load_env()
        session_path = messaging._whatsapp_session_path()
        paired = _whatsapp_has_paired_identity(session_path)
        _, name, phone = messaging._whatsapp_linked_account_from_session(session_path) if paired else (None, None, None)
    return {
        "profile": _bot_settings_profile_name(params), "enabled": payload["enabled"], "paired": paired,
        "mode": env.get("WHATSAPP_MODE", ""), "allowed_users": env.get("WHATSAPP_ALLOWED_USERS", ""),
        "account_name": name, "account_phone": phone, "gateway_running": payload["gateway_running"],
        "state": payload["state"], "error_code": payload["error_code"], "error_message": payload["error_message"]}


def _wa_reload(profile_arg):
    messaging = _wa_messaging()
    if messaging._notify_multiplexer_hot_serve(profile_arg):
        return {"hot_served": True, "restart_started": False}
    outcome = messaging._restart_gateway_after(profile_arg, what="WhatsApp setup", label="WhatsApp setup")
    return {"hot_served": False, "restart_started": bool(outcome.get("restart_started")),
            "restart_busy": bool(outcome.get("restart_busy")), "restart_error": outcome.get("restart_error")}


def _wa_guarded(rid, label, fn):
    from fastapi import HTTPException
    try:
        return _ok(rid, fn())
    except HTTPException as exc:
        return _wa_http_error(rid, exc)
    except Exception:
        logger.exception("%s failed", label)
        return _err(rid, _WA_FAILED, "WhatsApp setup could not be completed")


@method("messaging.whatsapp.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _wa_guarded(rid, "messaging.whatsapp.status", lambda: _wa_status_payload(params))


@method("messaging.whatsapp.pair.start")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def start():
        messaging = _wa_messaging()
        body = messaging.WhatsAppOnboardingStart(
            mode=_wa_text(params, "mode"), allowed_users=_wa_text(params, "allowed_users"),
            profile=_wa_profile_arg(params), reset_session=bool(params.get("reset_session")))
        started = _wa_run(messaging.start_whatsapp_onboarding(body))
        return _wa_pairing_view(started["pairing_id"], messaging._whatsapp_onboarding_sessions[started["pairing_id"]])
    return _wa_guarded(rid, "messaging.whatsapp.pair.start", start)


@method("messaging.whatsapp.pair.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def poll():
        messaging = _wa_messaging()
        pairing_id, record = _wa_owned_record(messaging, params)
        return _wa_pairing_view(pairing_id, record)
    return _wa_guarded(rid, "messaging.whatsapp.pair.status", poll)


@method("messaging.whatsapp.pair.cancel")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def cancel():
        messaging = _wa_messaging()
        pairing_id, _record = _wa_owned_record(messaging, params)
        return _wa_run(messaging.cancel_whatsapp_onboarding(pairing_id))
    return _wa_guarded(rid, "messaging.whatsapp.pair.cancel", cancel)


@method("messaging.whatsapp.pair.apply")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def apply():
        messaging = _wa_messaging()
        pairing_id, _record = _wa_owned_record(messaging, params)
        body = messaging.WhatsAppOnboardingApply(
            mode=_wa_text(params, "mode"), allowed_users=_wa_text(params, "allowed_users"),
            profile=_wa_profile_arg(params))
        applied = _wa_run(messaging.apply_whatsapp_onboarding(pairing_id, body))
        return {"ok": bool(applied.get("ok")), "restart_started": bool(applied.get("restart_started")),
                "restart_busy": applied.get("restart_busy"), "restart_error": applied.get("restart_error")}
    return _wa_guarded(rid, "messaging.whatsapp.pair.apply", apply)


@method("messaging.whatsapp.configure")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def configure():
        messaging = _wa_messaging()
        mode = messaging._normalize_whatsapp_onboarding_mode(_wa_text(params, "mode"))
        allowed = messaging._normalize_whatsapp_allowed_users(_wa_text(params, "allowed_users"))
        with messaging._config_profile_scope(_wa_profile_arg(params)):
            messaging.save_env_value("WHATSAPP_MODE", mode)
            if allowed:
                messaging.save_env_value("WHATSAPP_ALLOWED_USERS", allowed)
        return {**_wa_status_payload(params), **_wa_reload(_wa_profile_arg(params))}
    return _wa_guarded(rid, "messaging.whatsapp.configure", configure)


@method("messaging.whatsapp.unpair")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def unpair():
        from fastapi import HTTPException
        messaging = _wa_messaging()
        profile_arg = _wa_profile_arg(params)
        with messaging._config_profile_scope(profile_arg):
            session_path = messaging._whatsapp_session_path()
            with messaging._whatsapp_onboarding_lock:
                messaging._prune_whatsapp_onboarding_sessions()
                if any(r.session_path == str(session_path) and (
                        r.status not in messaging._WHATSAPP_ONBOARDING_TERMINAL_STATUSES or r.session_reserved)
                       for r in messaging._whatsapp_onboarding_sessions.values()):
                    raise HTTPException(status_code=409, detail="A WhatsApp pairing is still active. Cancel it first.")
            messaging.save_env_value("WHATSAPP_ENABLED", "false")
            messaging._write_platform_enabled("whatsapp", False)
        reload = _wa_reload(profile_arg)
        with messaging._config_profile_scope(profile_arg):
            messaging._backup_whatsapp_session(session_path)
        return {**_wa_status_payload(params), **reload}
    return _wa_guarded(rid, "messaging.whatsapp.unpair", unpair)


@method("messaging.whatsapp_cloud.connect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    def connect():
        from fastapi import HTTPException
        messaging = _wa_messaging()
        fields = {key: (_wa_text(params, key) or "").strip() for key in _WA_CLOUD_ENV}
        if not fields["phone_number_id"] or not fields["access_token"]:
            raise HTTPException(status_code=400, detail="phone_number_id and access_token required")
        env = {_WA_CLOUD_ENV[key]: value for key, value in fields.items() if value}
        with messaging._config_profile_scope(_wa_profile_arg(params)):
            entry = messaging._require_platform("whatsapp_cloud")
            messaging._apply_platform_update("whatsapp_cloud", entry, messaging._env_value_rules("whatsapp_cloud"), env, [], True)
            home = _profile_home(params.get("profile"))
            payload = messaging._platform_payloads(Path(home) if home else None, [entry])[0]
        set_keys = {item["key"]: item["is_set"] for item in payload["env_vars"]}
        return {
            "profile": _bot_settings_profile_name(params), "enabled": payload["enabled"],
            "configured": payload["configured"],
            "phone_number_id_set": bool(set_keys.get(_WA_CLOUD_ENV["phone_number_id"])),
            "access_token_set": bool(set_keys.get(_WA_CLOUD_ENV["access_token"])),
            "app_secret_set": bool(set_keys.get(_WA_CLOUD_ENV["app_secret"])),
            "allowed_users_set": bool(set_keys.get(_WA_CLOUD_ENV["allowed_users"])),
            **_wa_reload(_wa_profile_arg(params))}
    return _wa_guarded(rid, "messaging.whatsapp_cloud.connect", connect)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
