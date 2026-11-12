from __future__ import annotations

from functools import partial
from pathlib import Path

from pydantic import ValidationError

from gateway import auth_prompts
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts.canonical_auth import (
    AuthBeginParams, AuthDeclineParams, AuthSigninParams, AuthSubmitCallbackParams, AuthSubmitCredentialParams,
    AuthSubmitOauthTokensParams)


def _parse(model, params):
    try:
        return model.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc


def _require_control(connection) -> None:
    if 'session:control' not in connection.actor.capabilities:
        raise RuntimeStoreError('permission_denied')


async def signin(connection, ref, params):
    _require_control(connection)
    parsed = _parse(AuthSigninParams, params)
    recorded, url = await auth_prompts.signin(connection.authority, parsed.request_id)
    return {'recorded': recorded, **({'authorization_url': url} if url else {})}


async def decline(connection, ref, params):
    _require_control(connection)
    parsed = _parse(AuthDeclineParams, params)
    return {'recorded': await auth_prompts.decline(connection.authority, parsed.request_id)}


async def submit_credential(connection, ref, params):
    _require_control(connection)
    try:
        parsed = AuthSubmitCredentialParams.model_validate(params)
    except ValidationError:
        raise RuntimeStoreError('invalid_params') from None
    outcome = await auth_prompts.submit_credential(connection.authority, parsed.request_id, parsed.value)
    return {'outcome': outcome.value}


async def submit_oauth_tokens(connection, ref, params):
    _require_control(connection)
    try:
        parsed = AuthSubmitOauthTokensParams.model_validate(params)
    except ValidationError:
        raise RuntimeStoreError('invalid_params') from None
    from tools import mcp_oauth_import
    home = Path(connection.authority.profile_id)
    server = parsed.service.partition(':')[2]
    tokens = mcp_oauth_import.OwnerTokens(**{
        key: value for key, value in parsed.model_dump().items() if key != 'service'})
    reason = await mcp_oauth_import.import_owner_tokens(home, server, tokens)
    if reason is not None:
        return {'ok': False, 'reason': reason}
    await auth_prompts.complete(connection.authority, home, parsed.service)
    return {'ok': True}


async def submit_callback(connection, ref, params):
    _require_control(connection)
    try:
        parsed = AuthSubmitCallbackParams.model_validate(params)
    except ValidationError:
        raise RuntimeStoreError('invalid_params') from None
    outcome, reason = await auth_prompts.submit_callback(connection.authority, parsed.request_id, parsed.value)
    return {'outcome': outcome.value, **({'reason': reason} if reason else {})}


async def begin(connection, ref, params):
    _require_control(connection)
    parsed = _parse(AuthBeginParams, params)
    from hermes_cli import model_provider_control as control
    from hermes_constants import profile_name_for_home
    from tools.auth_required import AuthNeed
    home = Path(connection.authority.profile_id)
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    bot = profile_name_for_home(home) or 'default'
    scope = set_hermes_home_override(home)
    try:
        pconfig = control.lookup(parsed.service.partition(':')[2])
        if pconfig is None:
            return {'outcome': 'unsupported', 'reason': 'Unknown provider.'}
        kind, why = control.kind_of(pconfig)
        if kind == 'unsupported':
            return {'outcome': 'unsupported', 'reason': why}
        if pconfig.slug in control.ACCOUNT_WIDE and bot != 'default':
            return {'outcome': 'refused',
                    'reason': 'This login is shared by every profile. Change it from the main profile.'}
        state = control.row_for(pconfig).state
    finally:
        reset_hermes_home_override(scope)
    opened = await auth_prompts.begin_signin(
        connection.authority, home, AuthNeed(parsed.service, 'expired' if state == 'expired' else 'missing'), bot)
    if isinstance(opened, auth_prompts.Resolution):
        return {'outcome': 'unavailable', 'reason': 'Open Pal on a device that can show the sign-in prompt.'}
    return {'outcome': 'started', 'request_id': opened.request_id}


def handlers(connection):
    return {'auth.begin': partial(begin, connection), 'auth.signin': partial(signin, connection), 'auth.decline': partial(decline, connection),
            'auth.submit_credential': partial(submit_credential, connection),
            'auth.submit_oauth_tokens': partial(submit_oauth_tokens, connection),
            'auth.submit_callback': partial(submit_callback, connection)}
