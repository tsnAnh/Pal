import logging
from pathlib import Path

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_TELEGRAM_INVALID = 4101
_TELEGRAM_NOT_FOUND = 4103
_TELEGRAM_FAILED = 5102
_TELEGRAM_UNREACHABLE = 5103
_TELEGRAM_TOKEN_KEY = "TELEGRAM_BOT_TOKEN"
_TELEGRAM_API = "https://api.telegram.org"
_TELEGRAM_PROBE_TIMEOUT = 8.0
_TELEGRAM_REFUSED_STATUSES = (401, 404)


def _telegram_messaging():
    from hermes_cli.web_routers import messaging
    return messaging


def _telegram_http_error(rid, exc):
    detail = str(exc.detail)
    if exc.status_code == 404:
        return _err(rid, _TELEGRAM_NOT_FOUND, detail)
    if exc.status_code < 500:
        return _err(rid, _TELEGRAM_INVALID, detail)
    return _err(rid, _TELEGRAM_FAILED, detail)


def _telegram_scope_dir(params):
    home = _profile_home(params.get("profile"))
    return Path(home) if home else None


def _telegram_status_payload(params):
    messaging = _telegram_messaging()
    entry = messaging._require_platform("telegram")
    payload = messaging._platform_payloads(_telegram_scope_dir(params), [entry])[0]
    fields = {item["key"]: item["is_set"] for item in payload["env_vars"]}
    return {
        "profile": _bot_settings_profile_name(params), "enabled": payload["enabled"], "configured": payload["configured"],
        "gateway_running": payload["gateway_running"], "state": payload["state"],
        "error_code": payload["error_code"], "error_message": payload["error_message"],
        "bot_token_set": bool(fields.get(_TELEGRAM_TOKEN_KEY)),
        "allowed_users_set": bool(fields.get("TELEGRAM_ALLOWED_USERS"))}


def _telegram_reload(profile_arg):
    messaging = _telegram_messaging()
    if bool(messaging._notify_multiplexer_hot_serve(profile_arg)):
        return {"hot_served": True, "restart_started": False}
    outcome = messaging._restart_gateway_after(profile_arg, what="Telegram connect", label="Telegram connect")
    return {"hot_served": False, "restart_started": bool(outcome.get("restart_started")),
            "restart_busy": bool(outcome.get("restart_busy")), "restart_error": outcome.get("restart_error")}


def _telegram_probe(token: str) -> str:
    """Ask Telegram's getMe whether ``token`` is live: ``accepted``, ``refused`` (invalid or revoked) or
    ``unreachable``. The token is in the request URL, so nothing here may log or re-raise the URL or the error text."""
    import http.client
    import urllib.error
    import urllib.request
    from hermes_cli.config import get_env_value
    proxy = (get_env_value("TELEGRAM_PROXY") or "").strip()
    handlers = [urllib.request.ProxyHandler({"https": proxy, "http": proxy})] if proxy else []
    try:
        with urllib.request.build_opener(*handlers).open(
                f"{_TELEGRAM_API}/bot{token}/getMe", timeout=_TELEGRAM_PROBE_TIMEOUT) as response:
            return "accepted" if response.status == 200 else "unreachable"
    except urllib.error.HTTPError as exc:
        return "refused" if exc.code in _TELEGRAM_REFUSED_STATUSES else "unreachable"
    except (OSError, http.client.HTTPException, ValueError) as exc:
        logger.warning("Telegram getMe could not be reached (%s)", type(exc).__name__)
        return "unreachable"


@method("messaging.telegram.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    try:
        return _ok(rid, _telegram_status_payload(params))
    except HTTPException as exc:
        return _telegram_http_error(rid, exc)
    except Exception:
        logger.exception("messaging.telegram.status failed")
        return _err(rid, _TELEGRAM_FAILED, "Could not read the Telegram connection")


@method("messaging.telegram.connect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    from hermes_cli.setup_platforms import _is_valid_telegram_bot_token
    token = str(params.get("bot_token") or "").strip()
    if not token or not _is_valid_telegram_bot_token(token):
        return _err(rid, _TELEGRAM_INVALID, "Telegram bot token must be the complete token from @BotFather, such as 123456789:ABC…")
    messaging = _telegram_messaging()
    try:
        entry = messaging._require_platform("telegram")
        verdict = _telegram_probe(token)
        if verdict == "refused":
            return _err(rid, _TELEGRAM_INVALID, "Telegram did not accept this token. It is invalid or was revoked.")
        if verdict != "accepted":
            return _err(rid, _TELEGRAM_UNREACHABLE, "Could not reach Telegram to check the token.")
        messaging._apply_platform_update(
            "telegram", entry, messaging._env_value_rules("telegram"), {_TELEGRAM_TOKEN_KEY: token}, [], True)
        reload = _telegram_reload(str(params.get("profile") or "").strip() or None)
        return _ok(rid, {**_telegram_status_payload(params), **reload})
    except HTTPException as exc:
        return _telegram_http_error(rid, exc)
    except Exception:
        logger.exception("messaging.telegram.connect failed")
        return _err(rid, _TELEGRAM_FAILED, "Could not save the Telegram connection")


@method("messaging.telegram.disconnect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    messaging = _telegram_messaging()
    try:
        entry = messaging._require_platform("telegram")
        messaging._apply_platform_update("telegram", entry, {}, {}, [_TELEGRAM_TOKEN_KEY], False)
        reload = _telegram_reload(str(params.get("profile") or "").strip() or None)
        return _ok(rid, {**_telegram_status_payload(params), **reload})
    except HTTPException as exc:
        return _telegram_http_error(rid, exc)
    except Exception:
        logger.exception("messaging.telegram.disconnect failed")
        return _err(rid, _TELEGRAM_FAILED, "Could not remove the Telegram connection")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
