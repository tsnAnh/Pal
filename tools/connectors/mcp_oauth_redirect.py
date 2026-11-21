"""Redirect kinds for the Pal app's MCP sign-in, the app redirect URI, and the refusal classifiers."""

from __future__ import annotations

import re
from urllib.parse import urlparse

APP_REDIRECT_SCHEME = "dev.tsnanh.hermes.bot"
APP_REDIRECT_URI = f"{APP_REDIRECT_SCHEME}:/mcp-oauth/callback"
APP_DONE_URL = f"{APP_REDIRECT_SCHEME}://mcp-oauth/done"
GATEWAY_CALLBACK_PATH = "/webapp/mcp-oauth/callback"
CLIENT_METADATA_PATH = "/webapp/oauth/client-metadata.json"
CLIENT_NAME = "Pal"

KIND_APP = "app"
KIND_GATEWAY = "gateway"
KIND_LOOPBACK = "loopback"
CHAIN = (KIND_APP, KIND_GATEWAY, KIND_LOOPBACK)

_REFUSAL_CODES = ("invalid_redirect_uri", "invalid_client_metadata")
_ONLY_SECURE_REDIRECT = re.compile(
    r"redirect.{0,120}\b(only|must)\b.{0,40}\b(https|loopback|localhost)\b"
    r"|\b(only|must)\b.{0,40}\b(https|loopback)\b.{0,60}redirect", re.DOTALL)


def client_metadata_url(public_url: str) -> str:
    return public_url.rstrip("/") + CLIENT_METADATA_PATH


def client_metadata_document(public_url: str) -> dict:
    return {
        "client_id": client_metadata_url(public_url),
        "client_name": CLIENT_NAME,
        "redirect_uris": [public_url.rstrip("/") + GATEWAY_CALLBACK_PATH],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    }


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


ADMIN_APPROVAL_PENDING = "ADMIN_APPROVAL_PENDING"
ADMIN_APPROVAL_MESSAGE = "An admin of your organisation needs to approve Pal."
_ADMIN_CODES = ("consent_required", "interaction_required")
_ADMIN_WORDS = re.compile(
    r"\baadsts(90094|90095|65001)\b"
    r"|\badmin(istrator)?s?\b.{0,80}\b(approv\w*|consent\w*|authori[sz]\w*)"
    r"|\b(approv\w*|consent\w*|authori[sz]\w*)\b.{0,80}\badmin", re.DOTALL)


def is_admin_approval_pending(error: str | None, description: str | None = None) -> bool:
    """True when the authorization server says a person in the owner's organisation must approve the app,
    not the owner: ``consent_required`` / ``interaction_required`` (the sign-in is already interactive, so
    the owner cannot resolve them), or any other error whose text or ``error_description`` asks for an
    admin's approval, consent or authorization (Entra AADSTS90094, Atlassian "site admin must authorize",
    Notion "workspace owner or admin to approve"). A plain ``access_denied`` is the owner saying no."""
    code = str(error or "").strip().lower()
    if code in _ADMIN_CODES:
        return True
    return bool(_ADMIN_WORDS.search(f"{code} {str(description or '').lower()}"))
