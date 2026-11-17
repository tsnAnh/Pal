"""Redirect kinds for the Pal app's MCP sign-in, the app redirect URI, and the registration-refusal classifier."""

from __future__ import annotations

import re
from urllib.parse import urlparse

APP_REDIRECT_SCHEME = "dev.tsnanh.hermes.bot"
APP_REDIRECT_URI = f"{APP_REDIRECT_SCHEME}:/mcp-oauth/callback"
APP_DONE_URL = f"{APP_REDIRECT_SCHEME}://mcp-oauth/done"
GATEWAY_CALLBACK_PATH = "/webapp/mcp-oauth/callback"

KIND_APP = "app"
KIND_GATEWAY = "gateway"
KIND_LOOPBACK = "loopback"
CHAIN = (KIND_APP, KIND_GATEWAY, KIND_LOOPBACK)

_REFUSAL_CODES = ("invalid_redirect_uri", "invalid_client_metadata")
_ONLY_SECURE_REDIRECT = re.compile(
    r"redirect.{0,120}\b(only|must)\b.{0,40}\b(https|loopback|localhost)\b"
    r"|\b(only|must)\b.{0,40}\b(https|loopback)\b.{0,60}redirect", re.DOTALL)


def is_app_redirect(uri: str | None) -> bool:
    return urlparse(str(uri or "").strip()).scheme.lower() == APP_REDIRECT_SCHEME


def normalize_app_redirect(uri: str) -> str:
    """``dev.tsnanh.hermes.bot:/<path>``; no authority, userinfo, query or fragment, and a non-empty path."""
    parsed = urlparse(uri.strip())
    path = parsed.path
    if (parsed.scheme.lower() != APP_REDIRECT_SCHEME or parsed.netloc or parsed.query or parsed.fragment
            or parsed.params or path.strip("/") == "" or not path.startswith("/")):
        raise ValueError(f"client_redirect_uri must look like {APP_REDIRECT_URI}")
    return f"{APP_REDIRECT_SCHEME}:{path}"


def is_registration_refusal(text: str | None) -> bool:
    """True when an authorization server refused to register OUR redirect URI (RFC 7591 400 with
    ``invalid_redirect_uri`` / ``invalid_client_metadata``, or prose saying only https or loopback is
    allowed). Any other failure is not a reason to try another redirect."""
    lowered = str(text or "").lower()
    if "400" in lowered and any(code in lowered for code in _REFUSAL_CODES):
        return True
    return bool(_ONLY_SECURE_REDIRECT.search(lowered))
