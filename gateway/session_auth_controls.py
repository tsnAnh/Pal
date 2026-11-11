from __future__ import annotations

from functools import partial

from pydantic import ValidationError

from gateway import auth_prompts
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts.canonical_auth import AuthDeclineParams, AuthSigninParams


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


def handlers(connection):
    return {'auth.signin': partial(signin, connection), 'auth.decline': partial(decline, connection)}
