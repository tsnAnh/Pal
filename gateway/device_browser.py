from __future__ import annotations

import json
import re
from urllib.parse import urlsplit

from tools.registry import tool_error

ALLOWED_SCHEMES = frozenset({"http", "https"})
_PASSWORD_HINT = re.compile(r"password|passwd|passcode|\bpwd\b|one-time|\botp\b", re.IGNORECASE)


def url_refusal(url: str) -> str | None:
    from tools.browser_url_policy import evaluate_url_safety
    from tools.url_safety import is_safe_url
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return "That is not a valid web address."
    if parts.scheme.lower() not in ALLOWED_SCHEMES or not parts.hostname:
        return "Only http and https pages can be opened on the user's device."
    blocked = evaluate_url_safety(url.strip())
    if blocked is not None:
        return str(blocked.get("error") or "That address is blocked by the browser URL policy.")
    if not is_safe_url(url.strip()):
        return "Blocked: URL targets a private or internal address."
    return None


def screen_args(args) -> str | None:
    url = getattr(args, "url", None)
    if url is not None:
        return url_refusal(url)
    selector = getattr(args, "selector", None)
    if selector is not None and hasattr(args, "submit") and _PASSWORD_HINT.search(selector):
        return ("Typing into a password or one-time-code field is refused. Ask the user to type it themselves "
                "on the device.")
    return None


def host_of(url: str) -> str:
    try:
        return (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def sign_in_needed(spec, view, data: dict) -> str:
    from tools.auth_required import auth_required_result
    host = host_of(data.get("url", "")) or "this site"
    return auth_required_result(
        f"site:{host}", "missing", flow="manual",
        message=f"{host} wants a sign-in before {spec.name} can read it. Nothing was typed. The page is open in "
                f"the browser on {view.label}: the user signs in there themselves, then you read the page again.")


def finalize(spec, view, data: dict) -> str | None:
    url = data.get("url")
    if isinstance(url, str) and url and (refusal := url_refusal(url)) is not None:
        return tool_error(f"{view.label} ended on a page this bot may not read. {refusal}", code="blocked",
                          action=spec.name)
    if data.get("login_required"):
        return sign_in_needed(spec, view, data)
    return None
