"""Owner-only (no secondary-profile ticket) and app-only: never a model tool; bot sessions have no RPC channel."""

import logging

import httpx

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_GOOGLE_FORBIDDEN = 4403
_GOOGLE_INVALID = 4101
_GOOGLE_FAILED = 5321


def _google_owner_only(rid, action):
    from tui_gateway import google_workspace
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _GOOGLE_FORBIDDEN, "Only the owner can manage the Google Workspace sign-in")
    try:
        return _ok(rid, action(google_workspace))
    except google_workspace.WorkspaceError as exc:
        invalid = exc.code in ("invalid_client", "not_desktop_client", "invalid_services", "not_configured")
        return _err(rid, _GOOGLE_INVALID if invalid else _GOOGLE_FAILED, exc.message, {"code": exc.code})
    except (OSError, ValueError, KeyError, RuntimeError, httpx.HTTPError) as exc:
        logger.warning("google_workspace RPC failed (%s)", type(exc).__name__)
        return _err(rid, _GOOGLE_FAILED, "Couldn't update the Google Workspace sign-in on this computer.", {"code": "failed"})


@method("google_workspace.status")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.status())


@method("google_workspace.verify")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.verify())


@method("google_workspace.client.set")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.set_client(params.get("client_json"), params.get("client_id"),
                                                     params.get("client_secret")))


@method("google_workspace.signout")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.sign_out(remove_setup=bool(params.get("remove_setup"))))


@method("google_workspace.signin.start")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.start_signin(list(params["services"]), list(params.get("write_services") or [])))


@method("google_workspace.signin.finish")
def _(rid, params: dict) -> dict:
    return _google_owner_only(rid, lambda gw: gw.finish_signin(params["flow_id"], params["pasted"]))


@method("google_workspace.signin.cancel")
def _(rid, params: dict) -> dict:
    def cancel(gw):
        gw.cancel(params["flow_id"])
        return {"ok": True}
    return _google_owner_only(rid, cancel)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
