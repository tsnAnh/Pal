import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_ACCOUNT_SESSION_INVALID = 4101
_ACCOUNT_SESSION_MAX_TOKEN_CHARS = 8192


def _account_session_webapp_home():
    import sys
    web_server = sys.modules.get("hermes_cli.web_server")
    home = getattr(getattr(getattr(web_server, "app", None), "state", None), "webapp_home", None)
    return Path(home) if home is not None else None


@method("auth.revoke_self")
def _(rid, params: dict) -> dict:
    refresh_token = params.get("refresh_token")
    access_token = params.get("access_token")
    for token in (refresh_token, access_token):
        if token is not None and (not isinstance(token, str) or len(token) > _ACCOUNT_SESSION_MAX_TOKEN_CHARS):
            return _err(rid, _ACCOUNT_SESSION_INVALID, "invalid token")
    if not refresh_token or not refresh_token.strip():
        return _err(rid, _ACCOUNT_SESSION_INVALID, "refresh_token required")
    from hermes_cli import webapp_sign_in
    from hermes_cli.dashboard_auth.revoke import revoke_refresh_token
    providers_revoked = revoke_refresh_token(refresh_token)
    forgotten = webapp_sign_in.forget_native_tokens(
        _account_session_webapp_home(), refresh_token, *([access_token] if access_token else []))
    logger.info("auth.revoke_self: providers=%d forgotten=%d", providers_revoked, forgotten)
    return _ok(rid, {"ok": True, "providers_revoked": providers_revoked, "forgotten": forgotten})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
