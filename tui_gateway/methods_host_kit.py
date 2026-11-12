import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_KIT_FORBIDDEN = 4403
_REPO_INVALID = 4101
_KIT_BUSY = 4409
_JOB_UNKNOWN = 4404
_KIT_FAILED = 5321
_ERROR_CODES = {"busy": _KIT_BUSY, "unknown_job": _JOB_UNKNOWN}


def _kit_owner_only(rid, action):
    from tui_gateway import kit_host
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        return _err(rid, _KIT_FORBIDDEN, "Only the owner can manage the kit")
    try:
        return _ok(rid, action(kit_host))
    except kit_host.KitFailure as exc:
        return _err(rid, _ERROR_CODES.get(exc.code, _KIT_FAILED), exc.message, exc.as_dict())
    except Exception:
        logger.exception("host.kit RPC failed")
        return _err(rid, _KIT_FAILED, "Couldn't run the kit on this computer.",
                    {"code": "failed", "message": "Couldn't run the kit on this computer.", "subcommand": None, "tail": None})


@method("host.kit.status")
def _(rid, params: dict) -> dict:
    return _kit_owner_only(rid, lambda kit: kit.run("status"))


@method("host.kit.update")
def _(rid, params: dict) -> dict:
    return _kit_owner_only(rid, lambda kit: kit.start("update", "update"))


@method("host.kit.add_project")
def _(rid, params: dict) -> dict:
    from tui_gateway import kit_host
    repo = params.get("repo")
    if not isinstance(repo, str) or not kit_host.REPO.fullmatch(repo) or ".." in repo:
        return _err(rid, _REPO_INVALID, "That doesn't look like owner/repo")
    return _kit_owner_only(rid, lambda kit: kit.start("add_project", "add-project", repo))


@method("host.kit.reload")
def _(rid, params: dict) -> dict:
    from tui_gateway import kit_host
    target = params.get("target")
    if target not in kit_host.RELOAD_TARGETS:
        return _err(rid, _REPO_INVALID, "Reload routes or gateway")
    return _kit_owner_only(rid, lambda kit: kit.start("reload", "reload", target))


@method("host.kit.job")
def _(rid, params: dict) -> dict:
    def read(kit):
        view = kit.get(str(params.get("job_id") or ""))
        if view is None:
            raise kit.KitFailure("unknown_job", "That kit operation is no longer known")
        return view
    return _kit_owner_only(rid, read)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
