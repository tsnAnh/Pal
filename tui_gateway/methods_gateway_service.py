import logging

from .method_ctx import HandlerRegistry, bind_module

logger = logging.getLogger(__name__)
_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped

_SERVICE_FAILED = 5201


def _service_control():
    from hermes_cli import gateway_service_control
    return gateway_service_control


def _service_host():
    return _service_control().HostServiceControl()


def _service_profile(params):
    from hermes_cli.web_server_gateway import _own_profile_selector
    return _own_profile_selector(str(params.get("profile") or "").strip() or None)


def _service_caller_is_owner():
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    return connection_profile_home() is None


@method("gateway.service.status")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        control = _service_control()
        return _ok(rid, control.snapshot(_service_host()).wire())
    except Exception:
        logger.exception("gateway.service.status failed")
        return _err(rid, _SERVICE_FAILED, "Could not read the Hermes service state")


@method("gateway.service.restart")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        result = _service_control().restart(
            _service_host(), _service_profile(params), force=bool(params.get("force")),
            owner=_service_caller_is_owner())
        return _ok(rid, result)
    except Exception:
        logger.exception("gateway.service.restart failed")
        return _err(rid, _SERVICE_FAILED, "Could not restart Hermes")


@method("gateway.service.install")
@_profile_scoped
def _(rid, params: dict) -> dict:
    try:
        return _ok(rid, _service_control().install(_service_host()))
    except Exception:
        logger.exception("gateway.service.install failed")
        return _err(rid, _SERVICE_FAILED, "Could not install the Hermes service")


def register(server) -> None:
    bind_module(globals(), server, skip=("_",))
