from tui_gateway.contracts.connectors import (
    ConnectorAccountsParams,
    ConnectorAccountsRemoveParams,
    ConnectorAccountsRenameParams,
    ConnectorErrorReason,
    ConnectorPolicySetParams,
    ConnectorToolsParams,
)

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


def _guarded(fn):
    def handler(rid, params):
        return _connector_guard(fn)(rid, params)

    return handler


def _account_method(params_model=None, *, creates_guest, invalid="", invalid_reason=ConnectorErrorReason.invalid_params,
                    unavailable, unavailable_message):
    """``creates_guest``: whether this entry point may create the guest identity when the user has
    none. The page's reads never do; they answer from what a caller without a token can see."""
    def decorate(fn):
        def handler(rid, params):
            from pydantic import ValidationError
            from tools.connectors.gateway.errors import GatewayAuthError

            with _desktop_page_vars():
                if gate_error := _account_gate_closed(rid):
                    return gate_error
                try:
                    request = params if params_model is None else params_model.model_validate(params)
                except ValidationError:
                    return _connector_rpc_error(rid, 4000, invalid_reason, invalid)
                if creates_guest and (identity_error := _account_identity_error(rid)):
                    return identity_error
                try:
                    return fn(rid, request)
                except GatewayAuthError as exc:
                    return _connector_auth_error(rid, exc)
                except Exception as exc:
                    if getattr(exc, "code", None) == "org_required":
                        return _connector_rpc_error(
                            rid, 4090, ConnectorErrorReason.org_required, "Select an organization to manage connector rules."
                        )
                    return _connector_rpc_error(rid, 5034, unavailable, unavailable_message)

        return handler

    return decorate


@method("connectors.tools")
@_profile_scoped
@_account_method(
    ConnectorToolsParams,
    creates_guest=True,
    invalid="slug and refresh are required parameters",
    unavailable=ConnectorErrorReason.tools_unavailable,
    unavailable_message="Connector tools are unavailable.",
)
def _(rid, request):
    from tools.connectors.gateway.errors import GatewayUnavailable
    from tools.connectors.portal.client import PortalConnectorClient
    from tools.connectors.portal.errors import InvalidConnectorSlug
    from tools.connectors.portal.tools_cache import read_tools
    from tui_gateway.contracts.connectors import ConnectorErrorReason, ConnectorToolsResult

    client = PortalConnectorClient()
    client.require_authentication()
    try:
        listing = read_tools(request.slug, client=client, refresh=request.refresh)
    except (InvalidConnectorSlug, GatewayUnavailable):
        return _connector_rpc_error(rid, 4041, ConnectorErrorReason.connector_not_found, "Connector not found.")
    return _ok(rid, ConnectorToolsResult.model_validate(listing, from_attributes=True).model_dump(mode="json"))


@method("connectors.accounts")
@_profile_scoped
@_account_method(
    ConnectorAccountsParams,
    creates_guest=False,
    invalid="connector must be a slug.",
    unavailable=ConnectorErrorReason.accounts_unavailable,
    unavailable_message="Connector accounts are unavailable.",
)
def _(rid, request):
    from tools.connectors.portal.client import PortalConnectorClient
    from tools.managed_tool_gateway import read_nous_access_token
    from tui_gateway.contracts.connectors import ConnectorAccountRow, ConnectorAccountsResult

    accounts = PortalConnectorClient().list_accounts() if read_nous_access_token() else []
    rows = [account for account in accounts if request.connector is None or account["connector"] == request.connector]
    result = ConnectorAccountsResult(accounts=[_account_row(account) for account in rows])
    return _ok(rid, result.model_dump(mode="json"))


def _account_row(account):
    from tui_gateway.contracts.connectors import ConnectorAccountRow

    return ConnectorAccountRow(
        connection_id=account["connectionId"],
        connector=account["connector"],
        status=account["status"],
        status_reason=account.get("statusReason"),
        label=account["label"],
        alias=account.get("alias"),
        active=account["active"],
        disabled=bool(account.get("disabled")),
        created_at=account["createdAt"],
        updated_at=account["updatedAt"],
    )


@method("connectors.accounts.rename")
@_profile_scoped
@_account_method(
    ConnectorAccountsRenameParams,
    creates_guest=True,
    invalid="connection_id and a valid alias are required.",
    unavailable=ConnectorErrorReason.accounts_unavailable,
    unavailable_message="Connector accounts are unavailable.",
)
def _(rid, request):
    from tools.connectors.gateway.errors import (
        GatewayAuthError,
        GatewayUnavailable,
        IdempotencyConflict,
        ToolGatewayError,
    )
    from tools.connectors.portal.client import PortalConnectorClient
    from tui_gateway.contracts.connectors import ConnectorErrorReason

    try:
        account = PortalConnectorClient().rename_account(request.connection_id, request.alias)
    except IdempotencyConflict:
        return _connector_rpc_error(rid, 4090, ConnectorErrorReason.alias_taken, "That name is already used.")
    except GatewayUnavailable as exc:
        if exc.code == "connection_not_found":
            return _connector_rpc_error(rid, 4041, ConnectorErrorReason.connection_not_found, "Connector account not found.")
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.accounts_unavailable, "Connector accounts are unavailable.")
    except GatewayAuthError:
        raise
    except ToolGatewayError as exc:
        if exc.code == "org_required":
            raise
        if exc.status == 400:
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "That name is invalid.")
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.accounts_unavailable, "Connector accounts are unavailable.")
    return _ok(rid, _account_row(account).model_dump(mode="json"))


@method("connectors.accounts.remove")
@_profile_scoped
@_account_method(
    ConnectorAccountsRemoveParams,
    creates_guest=True,
    invalid="connection_id is required.",
    unavailable=ConnectorErrorReason.accounts_unavailable,
    unavailable_message="Connector accounts are unavailable.",
)
def _(rid, request):
    from tools.connectors.gateway.errors import GatewayAuthError, GatewayUnavailable, ToolGatewayError
    from tools.connectors.portal.client import PortalConnectorClient
    from tui_gateway.contracts.connectors import ConnectorAccountsRemoveResult, ConnectorErrorReason

    try:
        removed = PortalConnectorClient().delete_account(request.connection_id)
    except GatewayUnavailable as exc:
        if exc.code == "connection_not_found":
            return _connector_rpc_error(rid, 4041, ConnectorErrorReason.connection_not_found, "Connector account not found.")
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.accounts_unavailable, "Connector accounts are unavailable.")
    except GatewayAuthError:
        raise
    except ToolGatewayError as exc:
        if exc.code == "org_required":
            raise
        if exc.code == "invalid_connection_id":
            return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_params, "Connection id is invalid.")
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.accounts_unavailable, "Connector accounts are unavailable.")
    result = ConnectorAccountsRemoveResult(
        connection_id=removed["connectionId"], connector=removed["connector"], status=removed["status"]
    )
    return _ok(rid, result.model_dump(mode="json"))


@method("connectors.policy.get")
@_profile_scoped
@_account_method(
    creates_guest=False,
    unavailable=ConnectorErrorReason.policy_unavailable,
    unavailable_message="Connector policy is unavailable.",
)
def _(rid, _params):
    from tools.connectors.gateway.errors import GatewayAuthError, ToolGatewayError
    from tools.connectors.portal.client import PortalConnectorClient
    from tui_gateway.contracts.connectors import ConnectorErrorReason, ConnectorPolicyGetResult, ConnectorPolicyLayer

    try:
        client = PortalConnectorClient()
        client.require_authentication()
        policy = client.policy()
    except GatewayAuthError as exc:
        return _connector_rpc_error(rid, *_policy_auth_error(exc, ConnectorErrorReason))
    except ToolGatewayError as exc:
        return _connector_rpc_error(rid, *_policy_error(exc, ConnectorErrorReason))
    result = ConnectorPolicyGetResult(
        layers=[
            ConnectorPolicyLayer(kind=layer.kind, revision=layer.revision, body=_contract_policy_body(layer.body))
            for layer in policy.layers
        ],
        effective=_contract_policy_effective(policy.effective),
    )
    return _ok(rid, result.model_dump(mode="json"))


@method("connectors.policy.set")
@_profile_scoped
@_account_method(
    ConnectorPolicySetParams,
    creates_guest=True,
    invalid="Connector parameters are invalid.",
    unavailable=ConnectorErrorReason.policy_unavailable,
    unavailable_message="Connector policy is unavailable.",
)
def _(rid, request):
    from tools.connectors.gateway.errors import GatewayAuthError, ToolGatewayError
    from tools.connectors.portal.client import PortalConnectorClient
    from tools.connectors.portal.policy import InvalidMemberPolicy, compose_connector_write, compose_tools_write
    from tui_gateway.contracts.connectors import ConnectorErrorReason, ConnectorPolicySetResult, ToolsChange

    try:
        client = PortalConnectorClient()
        client.require_authentication()
        policy = client.policy()
        member = next((layer.body for layer in policy.layers if layer.kind == "member"), None)
        compose = compose_tools_write if isinstance(request.change, ToolsChange) else compose_connector_write
        body = compose(member, request.change)
        body["expectedRevision"] = request.expected_revision
        result = client.set_policy(body)
    except GatewayAuthError as exc:
        return _connector_rpc_error(rid, *_policy_auth_error(exc, ConnectorErrorReason))
    except InvalidMemberPolicy:
        return _connector_rpc_error(rid, 4000, ConnectorErrorReason.invalid_policy, "Connector policy change is invalid.")
    except ToolGatewayError as exc:
        return _connector_rpc_error(rid, *_policy_error(exc, ConnectorErrorReason))
    return _ok(rid, ConnectorPolicySetResult(
        revision=result.revision, effective=_contract_policy_effective(result.effective)
    ).model_dump(mode="json"))


def _policy_rule_fields(body):
    from tui_gateway.contracts.connectors import ConnectorPolicyTags

    if body.mode in ("unrestricted", "deny-all"):
        return {}
    tags = None if body.tags is None else ConnectorPolicyTags(enable=body.tags.enable, disable=body.tags.disable)
    rules = {"tools": {connector: rule.disable for connector, rule in body.tools.items()}, "tags": tags}
    if body.mode == "allow":
        return {"connectors": body.connectors, **rules}
    return {"disabled_connectors": body.disabled_connectors, **rules}


def _contract_policy_body(body):
    from tui_gateway.contracts import connectors as contract

    models = {
        "unrestricted": contract.ConnectorPolicyUnrestrictedBody,
        "deny-all": contract.ConnectorPolicyDenyAllBody,
        "allow": contract.ConnectorPolicyAllowBody,
        "deny": contract.ConnectorPolicyDenyBody,
    }
    return models[body.mode](mode=body.mode, **_policy_rule_fields(body))


def _contract_policy_effective(effective):
    from tui_gateway.contracts import connectors as contract

    models = {
        "unrestricted": contract.ConnectorPolicyEffectiveUnrestricted,
        "deny-all": contract.ConnectorPolicyEffectiveDenyAll,
        "allow": contract.ConnectorPolicyEffectiveAllow,
        "deny": contract.ConnectorPolicyEffectiveDeny,
    }
    return models[effective.mode](
        mode=effective.mode, version=effective.version, revision=effective.revision,
        issued_at_ms=effective.issued_at_ms, **_policy_rule_fields(effective),
    )


def _policy_auth_error(exc, reasons):
    if exc.code in {"no_access", "ORG_ACCESS_DENIED"}:
        return 4030, reasons.org_access_denied, "This account cannot manage connectors for this organization."
    if exc.code == "forbidden":
        return 4030, reasons.forbidden_scope, "Connector policy cannot be changed for this member."
    if exc.status == 401 or exc.code in {"invalid_token", "INVALID_TOKEN", "NO_TOKEN"}:
        return 4032, reasons.needs_nous_auth, "Sign in to use connectors."
    return 5034, reasons.policy_unavailable, "Connector policy is unavailable."


def _policy_error(exc, reasons):
    by_code = {
        "policy_changed": (4090, reasons.policy_conflict, "Connector policy changed. Refresh and try again."),
        "org_required": (4090, reasons.org_required, "Select an organization to manage connector rules."),
        "forbidden": (4030, reasons.forbidden_scope, "Connector policy cannot be changed for this member."),
        "no_access": (4030, reasons.org_access_denied, "This account cannot manage connectors for this organization."),
        "invalid_connector_policy": (4000, reasons.invalid_policy, "Connector policy change is invalid."),
    }
    if exc.code in by_code:
        return by_code[exc.code]
    if exc.code == f"HTTP_{exc.status}" and exc.status == 400:
        return 4000, reasons.invalid_policy, "Connector policy change is invalid."
    return 5034, reasons.policy_unavailable, "Connector policy is unavailable."


def _account_identity_error(rid):
    """Connecting from the Connectors page is the user asking for apps: create the guest identity
    here when the user has none. Page reads and operation polls never call this."""
    from tools.connectors import ensure_guest_identity
    from tui_gateway.contracts.connectors import ConnectorErrorReason

    if setup_error := ensure_guest_identity():
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.connector_request_failed, setup_error)
    return None


def _session_connector_gate(rid, session, action):
    import model_tools
    from tools.connectors import connectors_available

    agent = session.get("agent")
    enabled = agent.enabled_toolsets if agent is not None else _load_enabled_toolsets(_resolve_agent_platform(_session_source(session)))
    disabled = agent.disabled_toolsets if agent is not None else None
    if "manage_connections" not in model_tools._select_tool_names(enabled, disabled, quiet_mode=True) or not connectors_available():
        if action == "status":
            return enabled, disabled, _ok(rid, {"available": False, "connectors": []})
        return enabled, disabled, _connector_rpc_error(
            rid, *_refusals().CONNECTORS_UNAVAILABLE
        )
    return enabled, disabled, None


def _session_connector_rpc(rid, request, session, action):
    import json
    import model_tools
    import uuid

    from tools.connectors import live
    from tui_gateway.connector_payload import connector_ui_payload
    from tui_gateway.contracts.connectors import ConnectorErrorReason

    sid = request.owner.session_id
    enabled, disabled, error = _session_connector_gate(rid, session, action)
    if error:
        return error
    if not _connector_owner_matches(sid, session, session.get("profile_home")):
        return _connector_rpc_error(rid, 4001, ConnectorErrorReason.not_owner, "session ownership changed")
    args = {"action": "reconnect" if action == "connect" and request.reconnect else action}
    if action == "connect":
        args["connectors"] = request.connectors
    if action == "connect":
        operation = live.current(session["session_key"], profile_home=session.get("profile_home"))
        if operation is None:
            return _connector_rpc_error(
                rid, 4004, ConnectorErrorReason.unknown_operation, "No open connection operation for this session."
            )
        # A retry without an alias or id means the open target; one naming another account must not re-mint this one.
        if (request.alias is not None or request.connection_id is not None) and any(
                (target := operation.target(name)) is not None
                and ((request.alias is not None and target.alias != request.alias)
                     or request.connection_id not in (None, target.repair_id, target.connection_id))
                for name in request.connectors):
            return _connector_rpc_error(rid, *_refusals().UNKNOWN_TARGET_REFUSAL)
        return _reissue(rid, operation, args)
    raw = model_tools.handle_function_call(
        "manage_connections",
        args,
        task_id=session["session_key"],
        session_id=getattr(session.get("agent"), "session_id", None) or session["session_key"],
        tool_call_id=f"connector-ui-{uuid.uuid4().hex}",
        enabled_toolsets=enabled,
        disabled_toolsets=disabled,
    )
    data = json.loads(raw) if isinstance(raw, str) else raw
    if not isinstance(data, dict) or "error" in data:
        return _connector_rpc_error(rid, *_refusals().REQUEST_FAILED)
    if action == "status":
        if not isinstance(data.get("connectors"), list) or any(not isinstance(row, dict) for row in data["connectors"]):
            return _connector_rpc_error(rid, 5034, ConnectorErrorReason.invalid_connector_response, "Connector service returned an invalid response.")
        return _ok(rid, {"available": True, "connectors": _connector_rows(data["connectors"])})
    if not isinstance(data.get("targets"), list):
        return _connector_rpc_error(rid, 5034, ConnectorErrorReason.invalid_connector_response, "Connector service returned no authorization results.")
    return _ok(rid, connector_ui_payload(data))


def _connector_rows(rows):
    from tools.connectors.gateway.wire import ConnectorListItem
    from tui_gateway.connector_payload import connector_ui_payload

    return connector_ui_payload([
        ConnectorListItem.model_validate(row).model_dump(mode="json", by_alias=False)
        for row in rows
    ])


# Whether each account-owned action of the Connectors page may create the guest identity.
_ACCOUNT_CREATES_GUEST = {"status": False, "connect": True}


def _account_connector_list(rid):
    from hermes_cli.free_tier_offer import note_connected_apps_seen
    from tools.connectors.managed import managed_client
    from tools.managed_tool_gateway import read_nous_access_token

    rows = managed_client(creates_guest=False).list_connectors() if read_nous_access_token() else []
    note_connected_apps_seen(rows)
    return _ok(rid, {"available": True, "connectors": _connector_rows(rows)})


def _account_connector_connect(rid, request):
    from tools.connectors import account
    from tools.connectors.managed import DESKTOP_PAGE
    from tui_gateway.connector_payload import connector_ui_payload
    action = "reconnect" if request.reconnect else "connect"
    try:
        start = account.find_or_start_operation(
            request.connectors, action=action, profile_home=_account_home(request), alias=request.alias,
            repair_id=request.connection_id, initiator=DESKTOP_PAGE)
        if not start.started:
            from tools.connectors.contract import TargetState

            targets = [start.operation.target(name) for name in request.connectors]
            if any(target.state in (TargetState.failed, TargetState.expired) for target in targets):
                return _reissue(rid, start.operation, {"connectors": request.connectors}, initiator=DESKTOP_PAGE)
            return _ok(rid, connector_ui_payload(_operation_view(start.operation)))
        if not account.wait_for_prepare(start):
            return _ok(rid, connector_ui_payload(_operation_view(start.operation)))
        if start.failed:
            return _connector_rpc_error(rid, *_refusals().REQUEST_FAILED)
        return _ok(rid, connector_ui_payload(_operation_view(start.operation)))
    except ValueError:
        return _connector_rpc_error(rid, *_refusals().INVALID_PARAMS)


def _connector_rpc(rid, params, action):
    from tui_gateway.contracts.connectors import ConnectorErrorReason, ConnectorsConnectParams, ConnectorsListParams

    model = ConnectorsListParams if action == "status" else ConnectorsConnectParams
    request, session, error = _connector_params(rid, params, model)
    if error:
        return error
    if request.owner.type == "account":
        with _account_scope(request):
            if closed := _account_gate_closed(rid):
                return _ok(rid, {"available": False, "connectors": []}) if action == "status" else closed
            if _ACCOUNT_CREATES_GUEST[action] and (setup_error := _account_identity_error(rid)):
                return setup_error
            return _account_connector_list(rid) if action == "status" else _account_connector_connect(rid, request)

    runtime_token = _current_runtime_session_record.set(session)
    try:
        profile_home = session.get("profile_home")
        with _session_profile_runtime_scope({"profile_home": profile_home or str(_hermes_home)}):
            tokens = _set_session_context(session["session_key"], cwd=_session_cwd(session), ui_session_id=request.owner.session_id)
            try:
                result = _session_connector_rpc(rid, request, session, action)
            finally:
                _clear_session_context(tokens)
        if not _connector_owner_matches(request.owner.session_id, session, profile_home):
            return _connector_rpc_error(rid, 4001, ConnectorErrorReason.not_owner, "session ownership changed")
        return result
    finally:
        _current_runtime_session_record.reset(runtime_token)


def _reissue(rid, operation, args, *, initiator=None):
    from tools.connectors.run import reissue
    from tui_gateway.connector_payload import connector_ui_payload
    from tui_gateway.connector_refusals import REISSUE_REFUSALS

    reason = reissue(operation, args["connectors"], initiator=initiator)
    if reason in REISSUE_REFUSALS:
        return _connector_rpc_error(rid, *REISSUE_REFUSALS[reason])
    return _ok(rid, connector_ui_payload(_operation_view(operation)))


@method("connectors.list")
@_guarded
def _(rid, params):
    return _connector_rpc(rid, params, "status")


@method("connectors.connect")
@_guarded
def _(rid, params):
    return _connector_rpc(rid, params, "connect")


def register(server):
    from tools.connectors import hosted_install

    hosted_install.install()
    bind_module(globals(), server, skip=("_",))
    server._LONG_HANDLERS = server._LONG_HANDLERS | _registry.names()
