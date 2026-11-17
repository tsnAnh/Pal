"""The gateway's public https address (``webapp.public_url``): validate, read, save, suggest, check.

The apps need it for the Google, Slack and MCP sign-in callbacks. ``config.set`` refuses the key on
purpose (it is not in its allowlist of generic keys); this module is the one owner-only path that writes it.
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import re
import ssl
import subprocess
import urllib.parse
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Callable

MAX_LENGTH = 255
CALLBACK_PATH = "/webapp/mcp-oauth/callback"
PUBLIC_URL_KEY = "webapp.public_url"
_LABEL = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")
_CHECK_TIMEOUT_SECONDS = 8
_TAILSCALE_TIMEOUT_SECONDS = 5
_BODY_LIMIT = 64 * 1024


class Problem(StrEnum):
    too_long = "too_long"
    invalid = "invalid"
    not_https = "not_https"
    userinfo = "userinfo"
    ip_host = "ip_host"
    invalid_host = "invalid_host"
    path = "path"
    query_or_fragment = "query_or_fragment"


class AddressError(ValueError):
    def __init__(self, problem: Problem):
        super().__init__(problem.value)
        self.problem = problem


def normalise(raw: str) -> str:
    """The address as it is stored, or AddressError. An empty value is not an address: callers clear."""
    value = raw.strip()
    if len(value) > MAX_LENGTH:
        raise AddressError(Problem.too_long)
    if not value or any(c.isspace() or ord(c) < 32 or c in "\"'<>\\" for c in value):
        raise AddressError(Problem.invalid)
    try:
        parts = urllib.parse.urlsplit(value)
        port = parts.port
    except ValueError as exc:
        raise AddressError(Problem.invalid) from exc
    if parts.scheme.lower() != "https":
        raise AddressError(Problem.not_https)
    if "@" in parts.netloc:
        raise AddressError(Problem.userinfo)
    if parts.query or parts.fragment or "?" in value or "#" in value:
        raise AddressError(Problem.query_or_fragment)
    if parts.path not in ("", "/"):
        raise AddressError(Problem.path)
    host = (parts.hostname or "").rstrip(".").lower()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise AddressError(Problem.ip_host)
    labels = host.split(".")
    if len(labels) < 2 or len(host) > 253 or not all(_LABEL.match(label) for label in labels):
        raise AddressError(Problem.invalid_host)
    if port == 0:
        raise AddressError(Problem.invalid)
    return f"https://{host}" + (f":{port}" if port else "")


@dataclass(frozen=True)
class AddressState:
    url: str | None
    routes_enabled: bool
    suggestion: str | None


def tailnet_suggestion(run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> str | None:
    """``https://<this node's tailnet name>`` from ``tailscale status --json`` (read-only), or None when the
    CLI is missing, fails or names no usable host. Nothing about the tailnet is changed."""
    from hermes_platform.resolver import locate_command
    command = locate_command("tailscale").command
    if not command:
        return None
    try:
        done = run([*command, "status", "--json"], capture_output=True, text=True, timeout=_TAILSCALE_TIMEOUT_SECONDS,
                   check=False)
        name = json.loads(done.stdout)["Self"]["DNSName"]
        return normalise(f"https://{str(name).rstrip('.')}") if done.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AddressError):
        return None


def read(home: Path, *, suggest: Callable[[], str | None] | None = None) -> AddressState:
    from gateway.webapp_listener import webapp_settings
    settings = webapp_settings(home)
    return AddressState(url=settings.public_url or None, routes_enabled=settings.enabled,
                        suggestion=(suggest or tailnet_suggestion)())


class ManagedAddressError(RuntimeError):
    pass


def save(home: Path, raw: str) -> str | None:
    """Store the normalised address under ``webapp.public_url``, or clear it for an empty *raw*. The gateway
    reads the ``webapp:`` block when it starts, so a running listener keeps its earlier hosts until then."""
    from hermes_cli import managed_scope
    from hermes_cli.config_backend import write_config_key
    url = normalise(raw) if raw.strip() else None
    if managed_scope.is_key_managed(PUBLIC_URL_KEY):
        raise ManagedAddressError(PUBLIC_URL_KEY)
    write_config_key(Path(home) / "config.yaml", PUBLIC_URL_KEY, url)
    return url


class Outcome(StrEnum):
    reachable = "reachable"
    not_reachable = "not_reachable"
    wrong_service = "wrong_service"
    not_served = "not_served"
    no_address = "no_address"


_FAKE_STATE = "pal-address-check"
_NOT_SERVED_MARKER = "Invalid Host header"


def _fetch(url: str) -> tuple[int, str]:
    parts = urllib.parse.urlsplit(url)
    connection = http.client.HTTPSConnection(parts.netloc, timeout=_CHECK_TIMEOUT_SECONDS,
                                             context=ssl.create_default_context())
    try:
        connection.request("GET", f"{parts.path}?{parts.query}", headers={"User-Agent": "pal-address-check"})
        response = connection.getresponse()
        return response.status, response.read(_BODY_LIMIT).decode("utf-8", "replace")
    finally:
        connection.close()


def check(url: str | None, fetch: Callable[[str], tuple[int, str]] = _fetch) -> Outcome:
    """One GET of ``<url>/webapp/mcp-oauth/callback`` with a state nobody issued. Pal's own route answers that
    with its static 400 page; the Host-header guard of a gateway that does not serve the address answers a
    different 400, and anything else is another service. Redirects are not followed."""
    from hermes_cli.web_routers.mcp_oauth_callback import REJECTED_MESSAGE
    if not url:
        return Outcome.no_address
    query = urllib.parse.urlencode({"code": "x", "state": _FAKE_STATE})
    try:
        status, body = fetch(f"{url}{CALLBACK_PATH}?{query}")
    except (OSError, http.client.HTTPException, ssl.SSLError, ValueError):
        return Outcome.not_reachable
    if status == 400 and REJECTED_MESSAGE in body:
        return Outcome.reachable
    if status == 400 and _NOT_SERVED_MARKER in body:
        return Outcome.not_served
    return Outcome.wrong_service
