from __future__ import annotations

from agent.auxiliary_unavailable import ProviderNotConfiguredError
from agent.error_classifier import FailoverReason
from agent.i18n import t
from gateway.audience.model import Audience
from gateway.chat_bot_identity import installed_bot_name
from gateway.profile_routing import ProfileRouteRejected
from hermes_cli.auth import AuthError

MODEL_LOGIN_REASONS = frozenset({FailoverReason.auth.value, FailoverReason.auth_permanent.value})
UNAUTHORIZED = 401


def is_model_login_failure(exc: BaseException) -> bool:
    seen: set[int] = set()
    link: BaseException | None = exc
    while link is not None and id(link) not in seen:
        seen.add(id(link))
        if isinstance(link, (ProviderNotConfiguredError, AuthError)) or getattr(link, "status_code", None) == UNAUTHORIZED:
            return True
        link = link.__cause__ or link.__context__
    return False


def chat_failure_reply(runner, source, *, model_login: bool) -> str | None:
    if getattr(source, "audience", Audience.OWNER) is Audience.MEMBER:
        return t("gateway.errors.member_failed")
    if not model_login:
        return None
    try:
        home = runner._resolve_profile_home_for_source(source)
    except ProfileRouteRejected:
        return None
    return t("gateway.errors.pal_model_login") if installed_bot_name(home) is not None else None
