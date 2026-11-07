import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_PROFILE_ADMIN_INVALID = 4101
_PROFILE_ADMIN_REFUSED = 4102
_PROFILE_ADMIN_FAILED = 5101


def _profile_admin_hosting_refusal(name, profile_dir, action):
    from hermes_cli.profiles import normalize_profile_name
    if normalize_profile_name(name) == "default":
        return None
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    serving = {Path(_hermes_home).resolve()}
    ticket_home = connection_profile_home()
    if ticket_home:
        serving.add(Path(ticket_home).resolve())
    if Path(profile_dir).resolve() in serving:
        return f"This bot is serving this connection, so it cannot be {action}."
    return None


@method("profiles.rename")
def _(rid, params: dict) -> dict:
    new_name = str(params.get("new_name") or "").strip()
    name, profile_dir, err = _resolve_profile(rid, params)
    if err is not None:
        return err
    if not new_name:
        return _err(rid, _PROFILE_ADMIN_INVALID, "new_name required")
    if refusal := _profile_admin_hosting_refusal(name, profile_dir, "renamed"):
        return _err(rid, _PROFILE_ADMIN_REFUSED, refusal)
    from hermes_cli import profiles as profiles_mod
    try:
        path = profiles_mod.rename_profile(name, new_name)
        is_primary = profiles_mod.normalize_profile_name(name) == "default"
    except (ValueError, FileExistsError, FileNotFoundError, PermissionError) as e:
        return _err(rid, _PROFILE_ADMIN_REFUSED, str(e))
    except Exception as e:
        logger.exception("profiles.rename failed")
        return _err(rid, _PROFILE_ADMIN_FAILED, str(e))
    if is_primary:
        return _ok(rid, {"ok": True, "name": "default", "display_name": new_name.strip(), "path": str(path)})
    return _ok(rid, {"ok": True, "name": profiles_mod.normalize_profile_name(new_name), "path": str(path)})


@method("profiles.delete")
def _(rid, params: dict) -> dict:
    name, profile_dir, err = _resolve_profile(rid, params)
    if err is not None:
        return err
    from hermes_cli import profiles as profiles_mod
    canonical = profiles_mod.normalize_profile_name(name)
    if canonical == "default":
        return _err(rid, _PROFILE_ADMIN_REFUSED, "The primary bot cannot be deleted.")
    if refusal := _profile_admin_hosting_refusal(name, profile_dir, "deleted"):
        return _err(rid, _PROFILE_ADMIN_REFUSED, refusal)
    try:
        path = profiles_mod.delete_profile(name, yes=True)
    except profiles_mod.ProfileIdentitySettlementPending as pending:
        return _ok(rid, {"ok": True, "name": canonical, "path": str(pending.path), "identity_settled": False,
                         "settlement_pending": True, "retry_command": pending.retry_command})
    except (ValueError, FileNotFoundError, PermissionError) as e:
        return _err(rid, _PROFILE_ADMIN_REFUSED, str(e))
    except Exception as e:
        logger.exception("profiles.delete failed")
        return _err(rid, _PROFILE_ADMIN_FAILED, str(e))
    return _ok(rid, {"ok": True, "name": canonical, "path": str(path)})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
