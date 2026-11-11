import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_PROVIDERS_FAILED = 5301
_SHARED_LOGIN_REFUSAL = "This login is shared by every profile. Change it from the main profile."


def _providers_control():
    from hermes_cli import model_provider_control
    return model_provider_control


def _providers_profile_name():
    from hermes_constants import get_hermes_home, profile_name_for_home
    return profile_name_for_home(get_hermes_home()) or "default"


def _providers_row(provider_id):
    control = _providers_control()
    pconfig = control.lookup(provider_id)
    return control.row_for(pconfig).wire() if pconfig is not None else None


def _providers_shared_refusal(provider_id):
    return provider_id in _providers_control().ACCOUNT_WIDE and _providers_profile_name() != "default"


@method("model.providers.list")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        rows = [row.wire() for row in _providers_control().list_rows()]
        return _ok(rid, {"profile": _providers_profile_name(), "providers": rows})
    except Exception:
        logger.exception("model.providers.list failed")
        return _err(rid, _PROVIDERS_FAILED, "Could not read the model providers")


@method("model.providers.remove")
@_profile_scoped
def _(rid, params: dict) -> dict:
    provider_id = str(params.get("provider") or "")
    before = _providers_row(provider_id)
    if before is None or before["kind"] == "unsupported":
        return _ok(rid, {"outcome": "unsupported", "reason": (before or {}).get("reason") or "Unknown provider.",
                         "provider": before})
    if _providers_shared_refusal(provider_id):
        return _ok(rid, {"outcome": "refused", "reason": _SHARED_LOGIN_REFUSAL, "provider": before})
    if not before["can_remove"]:
        return _ok(rid, {"outcome": "nothing_to_remove", "provider": before})
    try:
        _providers_control().remove_credential(provider_id)
    except Exception:
        logger.exception("model.providers.remove failed for %s", provider_id)
        return _ok(rid, {"outcome": "failed", "reason": "Could not remove the credential. Nothing was changed.",
                         "provider": _providers_row(provider_id)})
    after = _providers_row(provider_id)
    if after["state"] == "set":
        return _ok(rid, {"outcome": "still_set", "provider": after, "reason":
                         "Another source still supplies a credential, such as the host's environment or a key shared with another provider."})
    return _ok(rid, {"outcome": "removed", "provider": after})


@method("model.providers.set_base_url")
@_profile_scoped
def _(rid, params: dict) -> dict:
    provider_id = str(params.get("provider") or "")
    before = _providers_row(provider_id)
    if before is None or not before["base_url_editable"]:
        return _ok(rid, {"outcome": "unsupported", "reason": "This provider has no editable address.",
                         "provider": before})
    given = params.get("base_url")
    control = _providers_control()
    if given is not None and (not isinstance(given, str) or control.valid_base_url(given) is None):
        return _ok(rid, {"outcome": "invalid", "reason": "Enter a full web address that starts with http:// or https://.",
                         "provider": before})
    try:
        control.set_base_url(provider_id, given)
    except Exception:
        logger.exception("model.providers.set_base_url failed for %s", provider_id)
        return _ok(rid, {"outcome": "failed", "reason": "Could not save the address. Nothing was changed.",
                         "provider": _providers_row(provider_id)})
    return _ok(rid, {"outcome": "reset" if given is None else "saved", "provider": _providers_row(provider_id)})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
