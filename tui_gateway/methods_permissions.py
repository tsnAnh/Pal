import threading

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_PERMISSIONS_ERR = 5320

_permissions_lock = threading.Lock()


def _permissions_failure(rid, code: str, message: str, **data) -> dict:
    return _err(rid, _PERMISSIONS_ERR, message, data={"code": code, **data})


def _permissions_state() -> dict:
    from tools import approval_rules
    from tools.approval_context import _get_approval_config, _normalize_approval_mode
    approvals = _get_approval_config()
    mode = _normalize_approval_mode(approvals.get("mode", "manual"))
    rules = approval_rules.parse(approvals.get("rules"))
    return {"auto_review": approval_rules.auto_review_enabled(mode), "approval_mode": mode,
            "ask": [rule.as_dict() for rule in rules.ask], "allow": [rule.as_dict() for rule in rules.allow]}


def _edit_permissions(rid, key: str, edit) -> dict:
    from hermes_cli.config_backend import ConfigWriteError
    from hermes_cli.config_read_errors import FailedConfigRead
    from tools.approval_rules import RuleError
    with _permissions_lock:
        cfg = _load_cfg_raw()
        if isinstance(cfg, FailedConfigRead):
            return _permissions_failure(
                rid, "config_unreadable", "The settings file could not be read, so nothing was changed.")
        approvals = cfg.get("approvals")
        try:
            updated, result = edit(approvals.get(key) if isinstance(approvals, dict) else None)
            if updated is not None:
                _write_config_key(f"approvals.{key}", updated)
        except RuleError as exc:
            return _permissions_failure(rid, exc.code, str(exc), **exc.data)
        except ConfigWriteError as exc:
            return _permissions_failure(rid, "config_locked", str(exc))
        return _ok(rid, result)


@method("permissions.get")
@_profile_scoped
def _(rid, params: dict) -> dict:
    return _ok(rid, _permissions_state())


@method("permissions.set_auto_review")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_cli.config_backend import ConfigWriteError
    from tools import approval_rules
    enabled = params.get("enabled")
    if not isinstance(enabled, bool):
        return _permissions_failure(rid, "invalid_enabled", "enabled is true or false.")
    with _permissions_lock:
        current = _permissions_state()["approval_mode"]
        target = approval_rules.mode_after_toggle(current, enabled)
        try:
            if target != current:
                _write_config_key("approvals.mode", target)
                _emit_all_session_info()
        except ConfigWriteError as exc:
            return _permissions_failure(rid, "config_locked", str(exc))
        return _ok(rid, _permissions_state())


@method("permissions.rules.add")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools import approval_rules

    def add(raw):
        which = approval_rules.parse_list_name(params.get("list"))
        updated, rule = approval_rules.add_rule(raw, which, params.get("text"))
        return updated, rule.as_dict()
    return _edit_permissions(rid, "rules", add)


@method("permissions.rules.remove")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from tools import approval_rules

    def remove(raw):
        updated, removed = approval_rules.remove_rule(raw, approval_rules.normalize_id(params.get("id")))
        return (updated if removed else None), {"removed": removed}
    return _edit_permissions(rid, "rules", remove)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
