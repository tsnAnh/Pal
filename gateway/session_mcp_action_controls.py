"""``mcp.actions.auto_approve.*``: the owner's per-chat switch that lets actions on an action-gated MCP server
(``tools/mcp_action_gate.py``) skip the approval card. Not a model tool and reachable only from an app
attached to the chat with ``session:approve``; the switch lives in memory and dies with the chat."""
import asyncio
from functools import partial

from hermes_state_runtime import RuntimeStoreError


def _chat_kind(authority, session_id):
    from gateway.config import Platform
    from gateway.session_iphone_toolset import SessionKind, session_kind
    from gateway.session_policy import restore_policy
    from hermes_state_local import local_receipt
    if authority.sessions[session_id].source.platform != Platform.LOCAL:
        return SessionKind.OTHER
    try:
        policy = restore_policy(local_receipt(authority.db, session_id)['policy'])
    except RuntimeStoreError:
        return SessionKind.OTHER
    return session_kind(authority, policy, session_id)


def _server_is_gated(server):
    from hermes_cli.mcp_config import _get_mcp_servers
    from tools.mcp_action_gate import policy_from_config
    return policy_from_config(_get_mcp_servers().get(server)) is not None


async def _attached_chat(connection, ref):
    authority, actor = connection.authority, connection.actor
    authority.authorize(actor, ref, 'session:approve')
    live = authority.sessions[ref.session_id]
    with live.event_stream.lock:
        if actor not in live.subscribers.values():
            raise RuntimeStoreError('permission_denied')
    return live


async def _eligible(connection, ref, live, server):
    from gateway.session_iphone_toolset import OWNER_APP_KINDS
    kind = await asyncio.to_thread(_chat_kind, connection.authority, ref.session_id)
    return kind in OWNER_APP_KINDS and await asyncio.to_thread(_server_is_gated, server)


async def get(connection, ref, params):
    from tools.mcp_action_gate import auto_approve_enabled
    live = await _attached_chat(connection, ref)
    server = params['server']
    eligible = await _eligible(connection, ref, live, server)
    return {'eligible': eligible, 'enabled': eligible and auto_approve_enabled(live.route, server)}


async def set_(connection, ref, params):
    from tools.mcp_action_gate import set_auto_approve
    live = await _attached_chat(connection, ref)
    server = params['server']
    if not await _eligible(connection, ref, live, server):
        raise RuntimeStoreError('permission_denied', field='server',
                                detail='auto-approve is only for the owner\'s app chats and action-gated servers')
    set_auto_approve(live.route, server, params['enabled'])
    return {'enabled': params['enabled']}


def handlers(connection):
    return {'mcp.actions.auto_approve.get': partial(get, connection),
            'mcp.actions.auto_approve.set': partial(set_, connection)}
