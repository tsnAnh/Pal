import asyncio
import importlib
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import Callable

from gateway.session_busy_controls import authorize_profile
from hermes_state_runtime import RuntimeStoreError

SIBLINGS = (
    'gateway.session_account_controls', 'gateway.session_library_controls', 'gateway.session_permissions_controls',
    'gateway.session_cron_controls', 'gateway.session_bot_settings_controls', 'gateway.session_bot_admin_controls',
    'gateway.session_display_controls', 'gateway.session_metrics_controls', 'gateway.session_connectors_controls',
    'gateway.session_mcp_controls', 'gateway.session_vault_controls', 'gateway.session_skills_controls',
)


class LegacyRefusal(RuntimeStoreError):
    def __init__(self, error):
        data = error.get('data')
        reason = data.get('reason') if isinstance(data, dict) else None
        super().__init__(reason if isinstance(reason, str) and reason else 'refused')
        code = error.get('code')
        self.wire_data = data if isinstance(data, dict) else {}
        self.wire_code = code if isinstance(code, int) else 5000
        self.wire_message = str(error.get('message') or self.reason)


@dataclass(frozen=True)
class Verb:
    scope: str | Callable[[dict], str]
    install_wide: bool = False
    named: tuple[str, ...] = ()
    guard: Callable[[dict], None] | None = None


def administers_install(connection) -> bool:
    from hermes_cli.profiles import profile_matches_home
    return connection.host_scoped or profile_matches_home('default', Path(connection.authority.profile_id))


def _require_reach(connection, verb, params):
    if administers_install(connection):
        return
    if verb.install_wide:
        raise RuntimeStoreError('permission_denied', field='profile', detail='this bot cannot manage the install')
    from hermes_cli.profiles import profile_matches_home
    home = Path(connection.authority.profile_id)
    for key in verb.named:
        value = params.get(key)
        if isinstance(value, str) and value.strip() and not profile_matches_home(value, home):
            raise RuntimeStoreError('profile_mismatch', field=key)


async def call(connection, method, params):
    from tui_gateway import server
    from tui_gateway.ws_legacy_fallback import dispatch_legacy
    request = {'jsonrpc': '2.0', 'id': method, 'method': method, 'params': dict(params)}
    reply = await asyncio.to_thread(dispatch_legacy, server, request, connection.transport, connection.actor,
                                    inline=True)
    if not isinstance(reply, dict):
        raise RuntimeStoreError('internal_error')
    if isinstance(reply.get('error'), dict):
        raise LegacyRefusal(reply['error'])
    if not isinstance(reply.get('result'), dict):
        raise RuntimeStoreError('internal_error')
    return reply['result']


async def serve(connection, method, verb, _ref, params):
    scope = verb.scope(params) if callable(verb.scope) else verb.scope
    authorize_profile(connection, params, scope)
    if verb.guard is not None:
        verb.guard(params)
    _require_reach(connection, verb, params)
    return await call(connection, method, params)


def bridged(connection, verbs):
    return {method: partial(serve, connection, method, verb) for method, verb in verbs.items()}


def action_scope(reads, writes):
    def scope(params):
        action = params.get('action', 'list')
        if action in reads:
            return 'session:read'
        if action in writes:
            return 'session:control'
        raise RuntimeStoreError('invalid_params', field='action')
    return scope


def account_owned(params):
    owner = params.get('owner')
    if not isinstance(owner, dict) or owner.get('type') != 'account':
        raise RuntimeStoreError('invalid_params', field='owner', detail='only the account owner is served here')


def handlers(connection):
    served = {}
    for module in SIBLINGS:
        served.update(importlib.import_module(module).handlers(connection))
    return served
