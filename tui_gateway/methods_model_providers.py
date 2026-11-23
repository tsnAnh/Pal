import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_PROVIDERS_FAILED = 5301
_PROBE_INVALID = 4001
_PROBE_SHARED_LOGIN = 4095
_PROBE_FAILED = 5302
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


def _providers_cli_plan_entry(provider_id):
    from hermes_cli.model_provider_cli_plan import CLI_PLAN_PROVIDERS
    return CLI_PLAN_PROVIDERS.get(provider_id) if isinstance(provider_id, str) else None


@method("model.providers.test")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_cli import model_provider_probe as probe
    provider_id = params.get("provider")
    before = _providers_row(provider_id) if isinstance(provider_id, str) and provider_id else None
    untestable = before is None or before["kind"] == "unsupported"
    try:
        parsed = probe.parse_params(params, base_url_editable=untestable or before["base_url_editable"])
    except probe.InvalidProbeParams as exc:
        return _err(rid, _PROBE_INVALID, str(exc))
    if untestable:
        return _ok(rid, probe.unsupported_result(parsed, (before or {}).get("reason") or "Unknown provider.").wire())
    if _providers_shared_refusal(parsed.provider):
        return _err(rid, _PROBE_SHARED_LOGIN, _SHARED_LOGIN_REFUSAL)
    try:
        return _ok(rid, probe.run_probe(parsed, before["kind"]).wire())
    except Exception as exc:  # health: allow BLE001 -- no exc_info on purpose: a provider error can echo the staged key
        logger.error("model.providers.test failed for %s (%s)", parsed.provider, type(exc).__name__)
        return _err(rid, _PROBE_FAILED, "Could not run the provider test")


@method("model.providers.host_check")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_cli import model_provider_cli_plan as cli_plan
    entry = _providers_cli_plan_entry(params.get("provider"))
    return _ok(rid, (cli_plan.host_check(entry) if entry else cli_plan.NO_HOST_CHECK).wire())


@method("model.providers.install_plugin")
@_profile_scoped
def _(rid, params: dict) -> dict:
    from hermes_cli import model_provider_cli_plan as cli_plan
    provider_id = str(params.get("provider") or "")
    entry = _providers_cli_plan_entry(provider_id)
    if entry is None:
        return _ok(rid, {"outcome": "unsupported", "reason": "This provider has no plugin to install.",
                         "provider": _providers_row(provider_id)})
    outcome, reason = cli_plan.install_plugin(entry)
    return _ok(rid, {"outcome": outcome, **({"reason": reason} if reason else {}),
                     "provider": _providers_row(provider_id)})


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
    # test = a network call of up to 60 s; install_plugin = a git clone; host_check reads sign-in evidence.
    server._LONG_HANDLERS = server._LONG_HANDLERS | {
        "model.providers.test", "model.providers.host_check", "model.providers.install_plugin"}
