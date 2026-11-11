from __future__ import annotations

from functools import partial

from pydantic import ValidationError

from gateway import auth_prompts
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts.canonical_auth import AuthDeclineParams, AuthSigninParams, AuthSubmitCredentialParams


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


def handlers(connection):
    return {'auth.signin': partial(signin, connection), 'auth.decline': partial(decline, connection),
            'auth.submit_credential': partial(submit_credential, connection)}
