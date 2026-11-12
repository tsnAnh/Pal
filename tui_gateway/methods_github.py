"""``github.*``: host-level GitHub sign-in through gh and the git/gh health check.

Owner-only: a connection bound to a secondary profile's ticket is refused, since the gh login is the host
user's and shared by every profile. Not a model tool, and bot sessions have no RPC channel.
Bodies are rebound onto server.py's globals (method_ctx.bind_module) and reference them bare.
"""

import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_GITHUB_FORBIDDEN = 4403
_GITHUB_FAILED = 5301


def _github_guarded(rid, action):
    from tui_gateway import github_signin
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _GITHUB_FORBIDDEN, "Only the owner can manage the GitHub sign-in")
    try:
        return _ok(rid, action(github_signin))
    except github_signin.SigninError as exc:
        return _err(rid, _GITHUB_FAILED, str(exc))
    except Exception:
        logger.exception("github RPC failed")
        return _err(rid, _GITHUB_FAILED, "Could not reach GitHub on this computer")


@method("github.status")
def _(rid, params: dict) -> dict:
    return _github_guarded(rid, lambda gh: gh.status())


@method("github.signin.start")
def _(rid, params: dict) -> dict:
    return _github_guarded(rid, lambda gh: gh.start())


@method("github.signin.poll")
def _(rid, params: dict) -> dict:
    return _github_guarded(rid, lambda gh: gh.poll(params["session_id"]))


@method("github.signin.cancel")
def _(rid, params: dict) -> dict:
    return _github_guarded(rid, lambda gh: gh.cancel(params["session_id"]))


@method("github.git_protocol.fix")
def _(rid, params: dict) -> dict:
    return _github_guarded(rid, lambda gh: gh.fix_git_protocol())


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
