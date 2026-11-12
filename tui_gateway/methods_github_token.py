"""``github.token.status`` and ``github.oauth.*``: the host's single GitHub token, set from the app through
Pal's OAuth device flow and applied through gh.

Owner-only: a connection bound to a secondary profile's ticket is refused, since the gh login is the host
user's and shared by every profile. Not a model tool, and bot sessions have no RPC channel.
Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging
import re

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_GITHUB_FORBIDDEN = 4403
_CLIENT_ID_INVALID = 4101
_GITHUB_TOKEN_FAILED = 5311
_CLIENT_ID = re.compile(r"^[A-Za-z0-9._-]{8,64}$")


def _owner_only(rid, action):
    from tui_gateway import github_oauth, github_token
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _GITHUB_FORBIDDEN, "Only the owner can manage the GitHub sign-in")
    try:
        return _ok(rid, action(github_token, github_oauth))
    except github_token.TokenError as exc:
        return _err(rid, _GITHUB_TOKEN_FAILED, exc.message, {"code": exc.code})
    except Exception:
        logger.exception("github RPC failed")
        return _err(rid, _GITHUB_TOKEN_FAILED, "Couldn't reach GitHub on this computer.", {"code": "unreachable"})


@method("github.token.status")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda token, oauth: token.github_token_state())


@method("github.oauth.start")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda token, oauth: oauth.start())


@method("github.oauth.poll")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda token, oauth: oauth.poll(params["session_id"]))


@method("github.oauth.cancel")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda token, oauth: oauth.cancel(params["session_id"]))


@method("github.oauth.config.get")
def _(rid, params: dict) -> dict:
    return _owner_only(rid, lambda token, oauth: {"client_id": token.configured_client_id()})


@method("github.oauth.config.set")
def _(rid, params: dict) -> dict:
    client_id = (params.get("client_id") or "").strip()
    if client_id and not _CLIENT_ID.match(client_id):
        return _err(rid, _CLIENT_ID_INVALID, "That doesn't look like a GitHub app client ID")

    def save(token, oauth):
        from hermes_cli.config import load_config, save_config
        config = load_config()
        auth = config.get("auth") if isinstance(config.get("auth"), dict) else {}
        github = auth.get("github") if isinstance(auth.get("github"), dict) else {}
        config["auth"] = {**auth, "github": {**github, "client_id": client_id}}
        save_config(config)
        oauth.cancel_all()
        return {"client_id": client_id or None}

    return _owner_only(rid, save)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
