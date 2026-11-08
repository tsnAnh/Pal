import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_SLACK_INVALID = 4101
_SLACK_NOT_FOUND = 4103
_SLACK_FAILED = 5102
_SLACK_ENV = ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN", "SLACK_ALLOWED_USERS")
_SLACK_CREATE_URL = "https://api.slack.com/apps?new_app=1&manifest_json="
_SLACK_MAX_ALLOWED_USERS = 50


def _slack_messaging():
    from hermes_cli.web_routers import messaging
    return messaging


def _slack_http_error(rid, exc):
    detail = str(exc.detail)
    if exc.status_code == 404:
        return _err(rid, _SLACK_NOT_FOUND, detail)
    if exc.status_code < 500:
        return _err(rid, _SLACK_INVALID, detail)
    return _err(rid, _SLACK_FAILED, detail)


def _slack_scope_dir(params):
    home = _profile_home(params.get("profile"))
    return Path(home) if home else None


def _slack_status_payload(params):
    messaging = _slack_messaging()
    entry = messaging._require_platform("slack")
    payload = messaging._platform_payloads(_slack_scope_dir(params), [entry])[0]
    fields = {item["key"]: item["is_set"] for item in payload["env_vars"]}
    return {
        "profile": _bot_settings_profile_name(params), "enabled": payload["enabled"], "configured": payload["configured"],
        "gateway_running": payload["gateway_running"], "state": payload["state"],
        "error_code": payload["error_code"], "error_message": payload["error_message"],
        "bot_token_set": bool(fields.get("SLACK_BOT_TOKEN")), "app_token_set": bool(fields.get("SLACK_APP_TOKEN")),
        "allowed_users_set": bool(fields.get("SLACK_ALLOWED_USERS"))}


def _slack_allowed_users(rid, raw):
    if raw is None:
        return "", None
    if not isinstance(raw, list) or len(raw) > _SLACK_MAX_ALLOWED_USERS or not all(isinstance(u, str) for u in raw):
        return None, _err(rid, _SLACK_INVALID, "allowed_users must be a list of Slack member IDs")
    return ",".join(u.strip() for u in raw if u.strip()), None


def _slack_reload(profile_arg):
    messaging = _slack_messaging()
    hot_served = bool(messaging._notify_multiplexer_hot_serve(profile_arg))
    if hot_served:
        return {"hot_served": True, "restart_started": False}
    outcome = messaging._restart_gateway_after(profile_arg, what="Slack connect", label="Slack connect")
    return {"hot_served": False, "restart_started": bool(outcome.get("restart_started")),
            "restart_busy": bool(outcome.get("restart_busy")), "restart_error": outcome.get("restart_error")}


@method("messaging.slack.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    try:
        return _ok(rid, _slack_status_payload(params))
    except HTTPException as exc:
        return _slack_http_error(rid, exc)
    except Exception as e:
        logger.exception("messaging.slack.status failed")
        return _err(rid, _SLACK_FAILED, str(e))


@method("messaging.slack.connect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    bot_token, app_token = (str(params.get(key) or "").strip() for key in ("bot_token", "app_token"))
    if not bot_token or not app_token:
        return _err(rid, _SLACK_INVALID, "bot_token and app_token required")
    allowed, err = _slack_allowed_users(rid, params.get("allowed_users"))
    if err is not None:
        return err
    messaging = _slack_messaging()
    env = {"SLACK_BOT_TOKEN": bot_token, "SLACK_APP_TOKEN": app_token}
    if allowed:
        env["SLACK_ALLOWED_USERS"] = allowed
    try:
        entry = messaging._require_platform("slack")
        messaging._apply_platform_update("slack", entry, messaging._env_value_rules("slack"), env, [], True)
        reload = _slack_reload(str(params.get("profile") or "").strip() or None)
        return _ok(rid, {**_slack_status_payload(params), **reload})
    except HTTPException as exc:
        return _slack_http_error(rid, exc)
    except Exception:
        logger.exception("messaging.slack.connect failed")
        return _err(rid, _SLACK_FAILED, "Could not save the Slack connection")


@method("messaging.slack.disconnect")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from fastapi import HTTPException
    messaging = _slack_messaging()
    try:
        entry = messaging._require_platform("slack")
        messaging._apply_platform_update("slack", entry, {}, {}, list(_SLACK_ENV), False)
        reload = _slack_reload(str(params.get("profile") or "").strip() or None)
        return _ok(rid, {**_slack_status_payload(params), **reload})
    except HTTPException as exc:
        return _slack_http_error(rid, exc)
    except Exception:
        logger.exception("messaging.slack.disconnect failed")
        return _err(rid, _SLACK_FAILED, "Could not remove the Slack connection")


@method("messaging.slack.manifest")
@_profile_scoped
def _(rid, params: dict) -> dict:
    import json
    from urllib.parse import quote
    from hermes_cli.profiles import get_profile_dir, read_profile_meta
    from hermes_cli.slack_cli import _build_full_manifest
    name = _bot_settings_profile_name(params)
    try:
        meta = read_profile_meta(get_profile_dir(name))
        bot_name = str(params.get("display_name") or "").strip() or meta.get("display_name") or name
        description = str(meta.get("description") or "").strip() or f"{bot_name} on Hermes"
        manifest = _build_full_manifest(
            bot_name, description, messaging_experience="none", include_slash_commands=False)
    except Exception as e:
        logger.exception("messaging.slack.manifest failed")
        return _err(rid, _SLACK_FAILED, str(e))
    encoded = quote(json.dumps(manifest, separators=(",", ":"), ensure_ascii=False), safe="")
    return _ok(rid, {"profile": name, "bot_name": bot_name[:35], "manifest": manifest,
                     "create_url": _SLACK_CREATE_URL + encoded})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
