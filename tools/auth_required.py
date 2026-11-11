from __future__ import annotations

import json
import re
import shlex
from dataclasses import dataclass
from typing import Any, Optional

ERROR_TYPE = "auth_required"
MAX_SCANNED_RESULT_CHARS = 200_000
REASONS = ("missing", "expired", "revoked")

_GH_LOGIN_HINT = re.compile(r"\bgh auth login\b", re.IGNORECASE)
_GH_REASONS = (
    ("revoked", re.compile(r"\b(token\b.{0,40}\brevoked|revoked\b.{0,40}\btoken)", re.IGNORECASE)),
    ("expired", re.compile(r"HTTP 401|bad credentials|token in \S+ is invalid|\bexpired\b", re.IGNORECASE)),
    ("missing", re.compile(r"not logged in|you are not logged into any github hosts|authentication required"
                           r"|to use github cli in automation, set the gh_token", re.IGNORECASE)),
)
_ENV_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SERVICE_NAMES = {"github": "GitHub"}


@dataclass(frozen=True, slots=True)
class AuthNeed:
    service: str
    reason: str = "missing"
    flow: Optional[str] = None


def service_display_name(service: str) -> str:
    return _SERVICE_NAMES.get(service, service.replace("_", " ").replace("-", " ").title() or service)


def auth_required_result(service: str, reason: str = "missing", *, flow: Optional[str] = None,
                         message: str = "") -> str:
    from tools.registry import tool_error
    reason = reason if reason in REASONS else "missing"
    body = {"service": service, "reason": reason, **({"flow": flow} if flow else {})}
    text = message or f"Sign-in to {service_display_name(service)} is required before this call can succeed."
    return tool_error(text, error_type=ERROR_TYPE, auth_required=body)


def http_auth_failure(service: str, status: int, headers: Any = None) -> Optional[str]:
    if status == 401 or (status == 403 and _has_auth_challenge(headers)):
        return auth_required_result(service, "expired" if status == 401 else "missing")
    return None


def _has_auth_challenge(headers: Any) -> bool:
    getter = getattr(headers, "get", None)
    return bool(getter and (getter("www-authenticate") or getter("WWW-Authenticate")))


def _gh_invoked(command: str) -> bool:
    try:
        words = shlex.split(command, posix=True)
    except ValueError:
        return False
    while words and _ENV_ASSIGNMENT.match(words[0]):
        words.pop(0)
    return bool(words) and words[0] == "gh"


def match_gh_failure(command: str, output: str, exit_code: Any) -> Optional[AuthNeed]:
    if isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code == 0:
        return None
    if not isinstance(command, str) or not isinstance(output, str) or not _gh_invoked(command):
        return None
    tail = output[-2000:]
    for reason, pattern in _GH_REASONS:
        if pattern.search(tail) and (reason == "missing" or _GH_LOGIN_HINT.search(tail)):
            return AuthNeed("github", reason, flow="device_code")
    return None


def detect(function_name: str, function_args: Any, result: Any) -> Optional[AuthNeed]:
    if not isinstance(result, str) or not result.startswith("{") or len(result) > MAX_SCANNED_RESULT_CHARS:
        return None
    if function_name != "terminal" and '"auth_required"' not in result and '"needs_reauth"' not in result:
        return None
    try:
        body = json.loads(result)
    except ValueError:
        return None
    if not isinstance(body, dict):
        return None
    typed = body.get("auth_required")
    if body.get("error_type") == ERROR_TYPE and isinstance(typed, dict) and isinstance(typed.get("service"), str):
        reason = typed.get("reason")
        flow = typed.get("flow")
        return AuthNeed(typed["service"], reason if reason in REASONS else "missing",
                        flow if isinstance(flow, str) else None)
    if body.get("needs_reauth") is True and isinstance(body.get("server"), str):
        return AuthNeed(f"mcp:{body['server']}", "expired", flow="oauth")
    if function_name == "terminal" and isinstance(function_args, dict):
        return match_gh_failure(function_args.get("command", ""), str(body.get("output", "")),
                                body.get("exit_code"))
    return None


_MESSAGES = {
    "declined": "The user declined sign-in to {name}. Do not retry this call or ask again; tell the user it needs "
                "{name} access.",
    "timed_out": "Sign-in to {name} timed out. Do not retry; tell the user it needs {name} access.",
    "failed": "Sign-in to {name} did not complete. Do not retry; tell the user it needs {name} access.",
    "no_app": "Sign-in is needed for {name} on {bot}, and the owner has no Pal app connected. Tell the owner in chat.",
    "retry_failed": "Signed in to {name}, but the call still failed to authenticate. Do not retry; tell the user.",
}


def _failure(kind: str, need: AuthNeed, bot: str, error_type: str) -> str:
    from tools.registry import tool_error
    text = _MESSAGES[kind].format(name=service_display_name(need.service), bot=bot)
    return tool_error(text, error_type=error_type, auth_required={"service": need.service})


def resolve(function_name: str, function_args: Any, result: Any, retry) -> Any:
    need = detect(function_name, function_args, result)
    if need is None:
        return result
    from gateway import auth_prompts
    from hermes_constants import get_hermes_home, profile_name_for_home
    home = get_hermes_home()
    bot = profile_name_for_home(home) or "default"
    outcome = auth_prompts.call_from_thread(home, need, bot)
    Resolution = auth_prompts.Resolution
    if outcome is Resolution.UNAVAILABLE:
        return result
    if outcome is Resolution.SIGNED_IN:
        retried = retry()
        if detect(function_name, function_args, retried) is None:
            return retried
        return _failure("retry_failed", need, bot, "auth_failed")
    kind = {Resolution.DECLINED: "declined", Resolution.TIMED_OUT: "timed_out",
            Resolution.NO_APP: "no_app"}.get(outcome, "failed")
    return _failure(kind, need, bot, {"declined": "auth_declined", "timed_out": "auth_timeout",
                                       "no_app": "auth_no_app"}.get(kind, "auth_failed"))
