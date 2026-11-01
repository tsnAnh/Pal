import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method

_TEMPLATE_ERROR_CODES = {
    "digest_mismatch": 4072,
    "name_unavailable": 4073,
    "unsupported_version": 4074,
    "too_large": 4075,
    "too_many_members": 4075,
}


def _template_error_code(code: str) -> int:
    return _TEMPLATE_ERROR_CODES.get(code, 4071)


def _template_payload(rid, params):
    import base64
    import binascii
    from hermes_cli import bot_template

    raw = params.get("data")
    if not isinstance(raw, str) or not raw.strip():
        return None, _err(rid, 4076, "template data required (base64)")
    if len(raw) > bot_template.MAX_ARCHIVE_BYTES * 4 // 3 + 16:
        return None, _err(rid, 4075, "This template is too large to import.")
    try:
        return base64.b64decode(raw, validate=True), None
    except (binascii.Error, ValueError):
        return None, _err(rid, 4076, "template data is not valid base64")


@method("profiles.template.export")
def _(rid, params: dict) -> dict:
    name, profile_dir, err = _resolve_profile(rid, params)
    if err is not None:
        return err
    import base64
    import hashlib
    from hermes_cli import bot_template
    try:
        with _hermes_home_scope(profile_dir):
            data = bot_template.export_template(name)
    except bot_template.BotTemplateError as e:
        return _err(rid, _template_error_code(e.code), str(e))
    except Exception as e:
        logger.exception("profiles.template.export failed")
        return _err(rid, 5071, str(e))
    return _ok(rid, {"filename": f"{name}{bot_template.TEMPLATE_EXTENSION}", "size": len(data),
                     "data": base64.b64encode(data).decode("ascii"), "sha256": hashlib.sha256(data).hexdigest()})


def _commit_template(rid, params: dict, data: bytes):
    from hermes_cli import bot_template
    from hermes_cli import profiles as profiles_mod
    try:
        created = bot_template.import_template(
            data, reviewed_digest=params.get("reviewed_digest"), name=str(params.get("name") or "").strip() or None,
            display_name=str(params.get("display_name") or "").strip() or None)
    except bot_template.BotTemplateError as e:
        return None, _err(rid, _template_error_code(e.code), str(e))
    except (ValueError, FileExistsError) as e:
        return None, _err(rid, 4073, str(e))
    except Exception as e:
        logger.exception("profiles.template.import failed")
        return None, _err(rid, 5071, str(e))
    path = Path(created["path"])
    if not is_truthy_value(params.get("no_alias", False)):
        _best_effort(lambda: profiles_mod.check_alias_collision(created["name"])
                     or profiles_mod.create_wrapper_script(created["name"]))
    mirrored = _mirror_launch_credentials(path, params)
    pin = created.pop("model_pin") or {}
    model_set = bool(pin.get("provider") and pin.get("default")) and _best_effort(
        lambda: _pin_profile_model(path, pin["provider"], pin["default"]))
    if not model_set and is_truthy_value(params.get("mirror_credentials", True)):
        mirrored["model_inherited"] = _try(lambda: _inherit_launch_model(path), False)
    return {"dry_run": False, "review": None, **created, "model_set": model_set, "mirrored": mirrored}, None


@method("profiles.template.import")
def _(rid, params: dict) -> dict:
    data, err = _template_payload(rid, params)
    if err is not None:
        return err
    from hermes_cli import bot_template
    if is_truthy_value(params.get("dry_run", False)):
        try:
            return _ok(rid, {"dry_run": True, "review": bot_template.inspect_template(data)})
        except bot_template.BotTemplateError as e:
            return _err(rid, _template_error_code(e.code), str(e))
        except Exception as e:
            logger.exception("profiles.template.import review failed")
            return _err(rid, 5071, str(e))
    result, err = _commit_template(rid, params, data)
    return err if err is not None else _ok(rid, result)


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
