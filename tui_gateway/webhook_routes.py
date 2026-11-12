"""Webhook routes for the owner's app: list, add, remove, and probe a route's local and public hop.

Routes live in the gateway home's ``webhook_subscriptions.json``, the file ``hermes webhook`` writes and the
webhook adapter re-reads on its next request. The probe only ever targets this gateway's own listener and the
configured ``webapp.public_url`` host, with a path built from a stored route name.
"""

from __future__ import annotations

import re
import secrets
import socket
import ssl
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import urlsplit

import httpx

PUBLIC_URL_SETTING = "webapp.public_url"
PROBE_TIMEOUT_SECONDS = 5.0
MIN_SECRET_LENGTH = 16
INSECURE_NO_AUTH = "INSECURE_NO_AUTH"
_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_WILDCARD_HOSTS = {"", "0.0.0.0", "::"}
_ROUTE_PORT_DEFAULT = 8644


class RouteError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Hop:
    status: int | None = None
    ms: int | None = None
    error: str | None = None

    def wire(self) -> dict:
        return {"status": self.status, "ms": self.ms, "error": self.error}


_DIAGNOSES = {
    "route_not_loaded": "The gateway doesn't have this route loaded (404 locally). Add it again, or check its profile is served.",
    "route_disabled": "The route exists but is switched off on the gateway.",
    "local_unreachable": "The webhook listener on this computer isn't answering. Webhook receiving isn't running.",
    "probe_skipped": "This route has signature checking switched off, so an unsigned test request would run it. No test was sent.",
    "local_unexpected": "The gateway's webhook listener answered with an unexpected status.",
}


def diagnose(local: Hop, public: Hop | None, public_configured: bool) -> tuple[str, str]:
    """``(code, message)``. *public* is None when no public request was made."""
    if local.error == "skipped":
        return "probe_skipped", _DIAGNOSES["probe_skipped"]
    if local.error or local.status is None:
        return "local_unreachable", _DIAGNOSES["local_unreachable"]
    if local.status == 404:
        return "route_not_loaded", _DIAGNOSES["route_not_loaded"]
    if local.status == 403:
        return "route_disabled", _DIAGNOSES["route_disabled"]
    if local.status not in (200, 202, 401):
        return "local_unexpected", f"{_DIAGNOSES['local_unexpected']} ({local.status})."
    local_note = "answers 401 (expected for an unsigned request)" if local.status == 401 else f"answers {local.status}"
    if not public_configured:
        return "public_unconfigured", (
            f"The local route {local_note}, but no public address is set ({PUBLIC_URL_SETTING}), so the public side wasn't tested.")
    assert public is not None
    if public.error:
        return _public_error(local_note, public.error)
    if public.status in (200, 202, 401):
        return "ok", f"The local route {local_note} and the public address answers {public.status}. The route is reachable."
    if public.status == 404:
        return "public_wrong_target", (
            f"The local route {local_note}, but the public address answers 404: the tunnel or proxy reaches something "
            "other than this gateway's webhook listener.")
    return "public_not_reaching_gateway", (
        f"The local route {local_note}, but the public address answers {public.status}: "
        "the tunnel or proxy is not reaching this gateway.")


def _public_error(local_note: str, error: str) -> tuple[str, str]:
    reason = {
        "timeout": ("public_timeout", "the public address didn't answer within the time limit: the tunnel or proxy is not reaching this gateway"),
        "tls": ("public_tls", "the public address's certificate was rejected: check the certificate and the tunnel's domain"),
        "dns": ("public_dns", "the public address's name doesn't resolve: check the DNS record"),
    }.get(error, ("public_unreachable", "the public address couldn't be connected to"))
    return reason[0], f"The local route {local_note}, but {reason[1]}."


def route_path(name: str, route: dict) -> str:
    profile = route.get("profile") or "default"
    prefix = f"/p/{profile}" if profile != "default" else ""
    return f"{prefix}/webhooks/{name}"


def public_base_url() -> str | None:
    from gateway.webapp_listener import webapp_settings
    from hermes_constants import get_hermes_home
    return webapp_settings(get_hermes_home()).public_url or None


def listener_address() -> tuple[bool, str, int]:
    from hermes_cli.webhook import _get_webhook_config
    config = _get_webhook_config()
    extra = config.get("extra") or {}
    host = str(extra.get("host") or "").strip()
    if host in _WILDCARD_HOSTS:
        host = "::1" if host == "::" else "127.0.0.1"
    try:
        port = int(extra.get("port", _ROUTE_PORT_DEFAULT))
    except (TypeError, ValueError):
        port = _ROUTE_PORT_DEFAULT
    return bool(config.get("enabled")), host, port


def _wire_route(name: str, route: dict, base: str | None) -> dict:
    path = route_path(name, route)
    events = route.get("events")
    return {
        "name": name,
        "profile": route.get("profile") or "default",
        "path": path,
        "public_url": f"{base}{path}" if base else None,
        "events": [e for e in events if isinstance(e, str)] if isinstance(events, list) else [],
        "deliver": str(route.get("cron_job") and f"cron job {route['cron_job']}" or route.get("deliver") or "log"),
        "description": str(route.get("description") or ""),
        "created_at": route.get("created_at") if isinstance(route.get("created_at"), str) else None,
        "enabled": route.get("enabled") is not False,
    }


def list_routes() -> dict:
    from hermes_cli.webhook import _load_subscriptions
    enabled = listener_address()[0]
    base = public_base_url()
    return {
        "enabled": enabled,
        "public_base_url": base,
        "public_url_setting": PUBLIC_URL_SETTING,
        "routes": [_wire_route(name, route, base) for name, route in _load_subscriptions().items() if isinstance(route, dict)],
    }


def add_route(params: dict) -> dict:
    """Create a route. A generated secret is returned in this result only."""
    from hermes_cli import webhook as store
    name = str(params.get("name") or "").strip().lower()
    if not _NAME.match(name):
        raise RouteError("invalid_name", "Use lowercase letters, numbers, hyphens and underscores.")
    typed = params.get("secret")
    generate = bool(params.get("generate_secret"))
    if generate == bool(typed):
        raise RouteError("invalid_secret", "Give a signing secret or ask for one to be generated.")
    if typed and (typed == INSECURE_NO_AUTH or len(typed) < MIN_SECRET_LENGTH):
        raise RouteError("invalid_secret", f"The signing secret needs at least {MIN_SECRET_LENGTH} characters.")
    if not listener_address()[0]:
        raise RouteError("webhook_disabled", "Webhook receiving isn't turned on for this gateway.")
    profile = _checked_profile(params.get("profile"))
    secret = secrets.token_urlsafe(32) if generate else typed
    route = {
        "description": f"Created from the app: {name}",
        "events": [e.strip() for e in params.get("events") or [] if isinstance(e, str) and e.strip()],
        "secret": secret,
        "prompt": "",
        "skills": [],
        "deliver": (params.get("deliver") or "log").strip() or "log",
        "profile": profile,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    try:
        published = store._replace_subscription(name, route, store._MISSING_SUBSCRIPTION)
    except store.SubscriptionMutationConflict as exc:
        raise RouteError("exists", "A route with that name already exists.") from exc
    return {"route": _wire_route(name, published, public_base_url()), "secret": secret if generate else None}


def _checked_profile(value) -> str:
    if value in (None, "", "default"):
        return "default"
    from hermes_cli.profiles import normalize_profile_name, profile_exists, validate_profile_name
    try:
        profile = normalize_profile_name(str(value))
        validate_profile_name(profile)
    except ValueError as exc:
        raise RouteError("invalid_profile", str(exc)) from exc
    if not profile_exists(profile):
        raise RouteError("invalid_profile", "That profile doesn't exist.")
    return profile


def remove_route(name: str) -> None:
    from hermes_cli.webhook import _mutate_subscriptions

    def remove(subscriptions: dict) -> None:
        if name not in subscriptions:
            raise KeyError(name)
        del subscriptions[name]

    try:
        _mutate_subscriptions(remove)
    except KeyError as exc:
        raise RouteError("not_found", "No route with that name.") from exc


def _stored_route(name: str) -> dict:
    from hermes_cli.webhook import _load_subscriptions
    route = _load_subscriptions().get(name) if _NAME.match(name or "") else None
    if not isinstance(route, dict):
        raise RouteError("not_found", "No route with that name.")
    return route


def _timed_post(client: httpx.Client, url: str) -> Hop:
    started = time.monotonic()
    try:
        response = client.post(url, content=b"{}", headers={"Content-Type": "application/json"})
    except httpx.TimeoutException:
        return Hop(error="timeout", ms=_ms(started))
    except httpx.ConnectError as exc:
        return Hop(error=_connect_error(exc), ms=_ms(started))
    except httpx.HTTPError:
        return Hop(error="unreachable", ms=_ms(started))
    return Hop(status=response.status_code, ms=_ms(started))


def _ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _connect_error(exc: BaseException) -> str:
    cause = exc
    while cause is not None:
        if isinstance(cause, ssl.SSLError):
            return "tls"
        if isinstance(cause, socket.gaierror):
            return "dns"
        cause = cause.__cause__ or cause.__context__
    return "unreachable"


def _cert_expiry(host: str, port: int) -> str | None:
    try:
        with socket.create_connection((host, port), timeout=PROBE_TIMEOUT_SECONDS) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
                not_after = (tls.getpeercert() or {}).get("notAfter")
        return datetime.fromtimestamp(ssl.cert_time_to_seconds(not_after), UTC).strftime("%Y-%m-%dT%H:%M:%SZ") if not_after else None
    except (OSError, ValueError):
        return None


def probe_route(name: str) -> dict:
    route = _stored_route(name)
    path = route_path(name, route)
    _, host, port = listener_address()
    bracketed = f"[{host}]" if ":" in host else host
    base = public_base_url()
    with httpx.Client(timeout=PROBE_TIMEOUT_SECONDS, follow_redirects=False, trust_env=False) as client:
        if route.get("secret") == INSECURE_NO_AUTH:
            local = Hop(error="skipped")
        else:
            local = _timed_post(client, f"http://{bracketed}:{port}{path}")
        public = None
        if base and local.status in (200, 202, 401):
            public = _timed_post(client, f"{base}{path}")
    tunnel = {"resolves": None, "tls_expires_at": None}
    if public is not None:
        tunnel["resolves"] = public.error != "dns"
        parts = urlsplit(base)
        if parts.scheme == "https" and parts.hostname and public.error is None:
            tunnel["tls_expires_at"] = _cert_expiry(parts.hostname, parts.port or 443)
    code, message = diagnose(local, public, bool(base))
    return {
        "local": local.wire(),
        "public": (public or Hop()).wire(),
        "diagnosis": {"code": code, "message": message},
        "tunnel": tunnel,
    }
