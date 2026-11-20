import asyncio
from functools import partial

from persistence.core.errors import AuthorityRefusal

from gateway.session_connections import ConnectorRefusal, _view, open_operation


def handlers(connection):
    return {'connectors.connect': partial(_handle, connection)}


async def _handle(connection, _ref, params):
    opened = await open_operation(connection, 'connectors.connect', params)
    return await asyncio.to_thread(_retry, opened.authority, opened.ref, opened.operation, opened.request)


def _retry(authority, ref, operation, request):
    """The card's Try again, under the session's own context, as the sidecar ran it for its session."""
    from tools.connectors import reissue
    from tools.connectors.gateway.errors import GatewayAuthError
    from tui_gateway.connector_refusals import (INVALID_PARAMS, REISSUE_REFUSALS, REISSUE_REFUSED, REQUEST_FAILED,
                                                UNKNOWN_TARGET_REFUSAL, auth_refusal)
    if not request.reconnect:
        raise ConnectorRefusal(*INVALID_PARAMS)
    for name in request.connectors:
        target = operation.target(name)
        # A retry naming another account must not re-mint this one.
        if target is not None and ((request.alias is not None and target.alias != request.alias)
                                   or request.connection_id not in (None, target.repair_id, target.connection_id)):
            raise ConnectorRefusal(*UNKNOWN_TARGET_REFUSAL)
    with _session_context(authority, ref):
        if operation.hosted:
            _require_connectors(authority, ref)
        try:
            reason = reissue.reissue(operation, request.connectors)
        except AuthorityRefusal:
            raise
        except GatewayAuthError as exc:
            raise ConnectorRefusal(*auth_refusal(exc)) from exc
        except Exception as exc:  # health: allow BLE001 -- the sidecar's _connector_guard: one named failure
            raise ConnectorRefusal(*REQUEST_FAILED) from exc
    if reason is not None:
        raise ConnectorRefusal(*REISSUE_REFUSALS.get(reason, REISSUE_REFUSED))
    return _view(operation)


def _require_connectors(authority, ref):
    """The sidecar's ``_session_connector_gate``: connectors on, and ``manage_connections`` in the session's tools."""
    import model_tools
    from tools.connectors import hosted_surface
    from tui_gateway import connector_refusals as refusals
    enabled, disabled = _session_toolsets(authority, ref)
    if 'manage_connections' not in model_tools._select_tool_names(enabled, disabled, quiet_mode=True) or not hosted_surface.available():
        raise ConnectorRefusal(*refusals.CONNECTORS_UNAVAILABLE)


def _session_toolsets(authority, ref):
    agent = authority.agent(ref)
    if agent is not None:
        return getattr(agent, 'enabled_toolsets', None), getattr(agent, 'disabled_toolsets', None)
    from agent.skill_utils import parse_config_string_list
    from gateway.session_policy import policy_for_source
    from toolsets import session_disabled_toolsets
    policy = policy_for_source(authority.runner, authority.sessions[ref.session_id].source)
    config = policy.config(authority, secrets=False) if policy is not None else {}
    enabled = list(policy.current_toolsets(config)) if policy is not None else None
    disabled = session_disabled_toolsets(parse_config_string_list((config.get('agent') or {}).get('disabled_toolsets')) or None,
                                         policy.platform if policy is not None else 'cli',
                                         oneshot=policy is not None and policy.source == 'oneshot')
    return enabled, disabled


def _session_context(authority, ref):
    """The session vars a turn of this session binds (``GatewayRunner._session_env_scope``), so a re-mint carries the turn's caller identity and session key."""
    from gateway.session import SessionContext
    from gateway.session_ancillary import physical_target
    live = authority.sessions[ref.session_id]
    context = SessionContext(source=live.source, connected_platforms=[], home_channels={},
                             session_key=live.route, session_id=physical_target(authority, ref))
    return authority.runner._session_env_scope(context)
