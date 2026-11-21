import contextlib
import contextvars

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_CONNECTOR_RPC_METHODS = frozenset({"connection.respond"})
_connector_rpc_origin: contextvars.ContextVar[tuple | None] = contextvars.ContextVar("connector_rpc_origin", default=None)


def _capture_connector_rpc_owner(params):
    owner = params.get("owner") if isinstance(params, dict) else None
    sid = owner.get("session_id") if isinstance(owner, dict) and owner.get("type") == "session" else ""
    _, session = _current_session_steer_authority(sid if isinstance(sid, str) else "")
    _connector_rpc_origin.set((session, session.get("profile_home") if session is not None else None))


def _connector_rpc_error(rid, code, reason, message):
    return _err(rid, code, message, data={"reason": reason})


def _refusals():
    from tui_gateway import connector_refusals

    return connector_refusals


def _connector_auth_error(rid, exc):
    from tui_gateway.connector_refusals import auth_refusal

    return _connector_rpc_error(rid, *auth_refusal(exc))


def _connector_guard(fn):
    def handler(rid, params):
        from tools.connectors.gateway.errors import GatewayAuthError
        from tui_gateway.connector_refusals import REQUEST_FAILED

        try:
            return fn(rid, params)
        except ProfileUnavailableError:
            raise
        except GatewayAuthError as exc:
            return _connector_auth_error(rid, exc)
        except Exception:
            return _connector_rpc_error(rid, *REQUEST_FAILED)

    return handler


def _connector_owner_matches(sid, owner, profile_home):
    _, current = _current_session_steer_authority(sid)
    return current is owner and not owner.get("_finalized") and owner.get("profile_home") == profile_home


def _session_owner(rid, owner):
    from tui_gateway.contracts.connectors import ConnectorErrorReason

    sid = owner.session_id
    _, session = _current_session_steer_authority(sid)
    origin = _connector_rpc_origin.get()
    if (session is None or session.get("_finalized")
            or origin is not None and (origin[0] is not session or origin[1] != session.get("profile_home"))):
        return None, _connector_rpc_error(
            rid, 4001, ConnectorErrorReason.not_owner, "session not found or not owned by this transport"
        )
    if _session_uses_compute_host(session):
        return None, _connector_rpc_error(
            rid, 5033, ConnectorErrorReason.unsupported_runtime, "Connectors must be managed on the session's compute host."
        )
    return session, None


def _parse_params(rid, params, model):
    from pydantic import ValidationError

    try:
        return model.model_validate(params), None
    except ValidationError:
        return None, _connector_rpc_error(rid, *_refusals().INVALID_PARAMS)


def _connector_params(rid, params, model):
    request, error = _parse_params(rid, params, model)
    if error:
        return None, None, error
    if request.owner.type == "account":
        return request, None, None
    session, error = _session_owner(rid, request.owner)
    return request, session, error


def _operation_params(rid, params):
    from tui_gateway.contracts.connectors_operation import ConnectionOperationParams

    return _connector_params(rid, params, ConnectionOperationParams)


def _account_home(request):
    home = _profile_home(request.profile)
    return str(home) if home else None


@contextlib.contextmanager
def _desktop_page_vars(source="desktop"):
    """Bind the session vars of a sessionless request from the desktop Connectors page. Only that
    page sends account-owned and account RPCs, so the surface comes from the request: the backend's
    ``HERMES_DESKTOP`` is absent on a URL or cloud backend and would name the caller ``tui``."""
    from gateway.session_context import set_session_vars

    tokens = set_session_vars(source=source, profile=_current_profile_name(), cron_session="")
    try:
        yield
    finally:
        _clear_session_context(tokens)


@contextlib.contextmanager
def _account_scope(request):
    with _session_profile_runtime_scope({"profile_home": _account_home(request)}), _desktop_page_vars(request.owner.source):
        yield


def _operation_for_request(rid, request, session):
    from tools.connectors import live
    from tools.connectors.hosted_switch import hosted_enabled
    if request.owner.type == "session":
        operation = live.get(session["session_key"], request.op_id, profile_home=session.get("profile_home"))
    else:
        with _account_scope(request):
            operation = live.get_by_op_id(request.op_id, profile_home=_account_home(request))
            if operation is not None and operation.hosted and not hosted_enabled():
                return None, _connector_rpc_error(rid, *_refusals().CONNECTORS_UNAVAILABLE)
    if operation is None:
        return None, _connector_rpc_error(rid, *_refusals().UNKNOWN_OPERATION)
    return operation, None


@method("connectors.operation.status")
@_connector_guard
def _(rid, params):
    from tui_gateway.connector_payload import connector_ui_payload

    request, session, error = _operation_params(rid, params)
    if error:
        return error
    operation, error = _operation_for_request(rid, request, session)
    return error or _ok(rid, connector_ui_payload(_operation_view(operation)))


@method("connectors.operation.wake")
@_connector_guard
def _(rid, params):
    request, session, error = _operation_params(rid, params)
    if error:
        return error
    operation, error = _operation_for_request(rid, request, session)
    if error:
        return error
    operation.wake.set()
    return _ok(rid, {"status": "ok"})


@method("connection.respond")
@_connector_guard
def _(rid, params):
    from pydantic import ValidationError

    from tui_gateway.connector_refusals import INVALID_ANSWER
    from tui_gateway.contracts.connectors_operation import ConnectionAnswer

    envelope = {key: value for key, value in params.items() if key != "result"}
    request, session, error = _operation_params(rid, envelope)
    if error:
        return error
    try:
        answer = ConnectionAnswer.model_validate(params.get("result"))
    except ValidationError:
        return _connector_rpc_error(rid, *INVALID_ANSWER)
    operation, error = _operation_for_request(rid, request, session)
    if error:
        return error
    if request.owner.type == "account":
        with _account_scope(request):
            return _apply_connection_answer(rid, answer, operation)
    with _session_profile_runtime_scope({"profile_home": session.get("profile_home") or str(_hermes_home)}):
        return _apply_connection_answer(rid, answer, operation)


def _apply_connection_answer(rid, answer, operation):
    from tools.connectors.operation import IllegalTransition
    from tools.connectors.run import respond
    from tui_gateway.connector_refusals import INVALID_ANSWER

    try:
        settled = respond(operation, answer.model_dump_json(exclude_none=True))
    except IllegalTransition:
        return _connector_rpc_error(rid, *INVALID_ANSWER)
    return _ok(rid, {"status": "ok", "settled": settled})


def _snapshot_view(snapshot):
    return {**snapshot, "settled": snapshot.get("settled_at") is not None}


def _operation_view(operation):
    return _snapshot_view(operation.snapshot())


def _connection_update(server, operation, change, snapshot):
    from hermes_constants import get_process_hermes_home, hermes_home_key
    from tui_gateway.connector_payload import connector_ui_payload

    payload = _snapshot_view(snapshot)
    if change:
        payload.update(change)
    if operation.session_key.startswith("account:"):
        payload["targets"] = [
            {key: value for key, value in target.items() if key not in ("connect_url", "connection_id")}
            for target in payload["targets"]
        ]
        payload["owner"] = {"type": "account"}
        server._broadcast_global_event("connection.update", connector_ui_payload(payload))
        return
    with server._sessions_lock:
        sid = next(
            (
                sid
                for sid, session in server._sessions.items()
                if session.get("session_key") == operation.session_key
                and hermes_home_key(session.get("profile_home") or get_process_hermes_home()) == operation.profile_key
            ),
            None,
        )
    if sid is not None:
        payload["owner"] = {"type": "session", "session_id": sid}
        server._emit("connection.update", sid, connector_ui_payload(payload))


def _install_update_hook(server):
    from functools import partial

    from tools.connectors import operation as op_module

    if getattr(op_module.ConnectionOperation, "_update_hook_installed", False):
        return
    op_module.ConnectionOperation._update_hook_installed = True
    op_module.ConnectionOperation.on_change = staticmethod(partial(_connection_update, server))


def register(server):
    bind_module(globals(), server, skip=("_",))
    server._LONG_HANDLERS = server._LONG_HANDLERS | _CONNECTOR_RPC_METHODS
    _install_update_hook(server)
