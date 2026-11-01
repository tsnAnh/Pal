import contextlib
import re
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Optional

from hermes_cli import webhook as webhook_store

ROUTE_PREFIX = "routine-"
BLOCKED_WEBHOOK_OFF = "webhook_disabled"
BLOCKED_GATEWAY_STOPPED = "gateway_stopped"
SECRET_BYTES = 32
_JOB_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class TriggerUnavailable(RuntimeError):
    def __init__(self, blocked_by: str):
        super().__init__(blocked_by)
        self.blocked_by = blocked_by


class TriggerConflict(RuntimeError):
    pass


@dataclass(frozen=True)
class WebhookHost:
    home: Path
    route_profile: str


def route_name_for(job_id: str) -> str:
    cleaned = str(job_id or "").strip()
    if not _JOB_ID_RE.match(cleaned):
        raise ValueError("That routine cannot have a trigger.")
    return f"{ROUTE_PREFIX}{cleaned.lower()}"


@contextlib.contextmanager
def _home_scope(home: Path) -> Iterator[None]:
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    token = set_hermes_home_override(str(home))
    try:
        yield
    finally:
        reset_hermes_home_override(token)


def _serving_host(profile: str) -> Optional[WebhookHost]:
    from gateway.host_attach import host_gateway_serving
    from hermes_cli.profiles import normalize_profile_name

    gateway = host_gateway_serving(profile or "default")
    if gateway is None:
        return None
    label = normalize_profile_name(gateway.profile_label or "default")
    own = normalize_profile_name(profile or "default") == label
    return WebhookHost(Path(gateway.home), "default" if own else normalize_profile_name(profile))


def _webhook_enabled(host: Optional[WebhookHost]) -> bool:
    if host is None:
        return webhook_store._is_webhook_enabled()
    with _home_scope(host.home):
        return webhook_store._is_webhook_enabled()


def require_host(profile: str) -> WebhookHost:
    host = _serving_host(profile)
    if not _webhook_enabled(host):
        raise TriggerUnavailable(BLOCKED_WEBHOOK_OFF)
    if host is None:
        raise TriggerUnavailable(BLOCKED_GATEWAY_STOPPED)
    return host


def _owns(route: Any, job_id: str, host: WebhookHost) -> bool:
    return (
        isinstance(route, dict)
        and route.get("cron_job") == job_id
        and str(route.get("profile", "default")) == host.route_profile)


def _new_route(job_id: str, host: WebhookHost) -> dict[str, Any]:
    return {
        "description": "Routine trigger",
        "events": [],
        "secret": secrets.token_urlsafe(SECRET_BYTES),
        "prompt": "",
        "skills": [],
        "deliver": "log",
        "profile": host.route_profile,
        "cron_job": job_id,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def routine_trigger_status(profile: str, job_id: str) -> dict[str, Any]:
    """Whether a webhook trigger can be offered for the routine and whether one exists. Never carries
    the key: it is shown once, when the trigger is created or regenerated."""
    name = route_name_for(job_id)
    host = _serving_host(profile)
    if not _webhook_enabled(host):
        return {"available": False, "blocked_by": BLOCKED_WEBHOOK_OFF, "configured": False}
    if host is None:
        return {"available": False, "blocked_by": BLOCKED_GATEWAY_STOPPED, "configured": False}
    with _home_scope(host.home):
        route = webhook_store._load_subscriptions().get(name)
        if not _owns(route, job_id, host):
            return {"available": True, "blocked_by": None, "configured": False}
        return {
            "available": True, "blocked_by": None, "configured": True,
            "url": webhook_store._route_url(name, route), "created_at": route.get("created_at")}


def issue_routine_trigger(profile: str, job_id: str) -> dict[str, Any]:
    """Create the routine's webhook trigger, or replace its key. The returned key is the only time it
    is disclosed. A route of the same name that is not this routine's is never overwritten."""
    name = route_name_for(job_id)
    host = require_host(profile)
    route = _new_route(job_id, host)

    def publish(subscriptions: dict[str, dict]) -> None:
        current = subscriptions.get(name)
        if current is not None and not _owns(current, job_id, host):
            raise TriggerConflict(name)
        subscriptions[name] = route

    with _home_scope(host.home):
        webhook_store._mutate_subscriptions(publish)
        url = webhook_store._route_url(name, route)
    return {"url": url, "key": route["secret"], "created_at": route["created_at"]}


def _removal_hosts(profile: str) -> list[WebhookHost]:
    serving = _serving_host(profile)
    if serving is not None:
        return [serving]
    from hermes_constants import get_default_hermes_root, get_hermes_home
    from hermes_cli.profiles import normalize_profile_name

    hosts = [WebhookHost(Path(get_hermes_home()), "default")]
    named = normalize_profile_name(profile or "default")
    if named != "default":
        hosts.append(WebhookHost(Path(get_default_hermes_root()), named))
    return hosts


def remove_routine_trigger(profile: str, job_id: str) -> bool:
    """Delete the routine's trigger route; True when one was removed. Idempotent when none exists, and
    a same-named route that is not this routine's is left alone. Works while the gateway is stopped, so
    a deleted routine never leaves a live endpoint behind."""
    name = route_name_for(job_id)

    def remove(subscriptions: dict[str, dict], host: WebhookHost) -> bool:
        if not _owns(subscriptions.get(name), job_id, host):
            return False
        del subscriptions[name]
        return True

    removed = False
    for host in _removal_hosts(profile):
        with _home_scope(host.home):
            if _owns(webhook_store._load_subscriptions().get(name), job_id, host):
                removed = bool(webhook_store._mutate_subscriptions(lambda subs, h=host: remove(subs, h))) or removed
    return removed
