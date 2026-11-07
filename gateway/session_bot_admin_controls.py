import asyncio
from functools import partial

from pydantic import ValidationError

from gateway.session_busy_controls import authorize_profile
from gateway.session_legacy_bridge import Verb, administers_install, bridged
from hermes_state_runtime import RuntimeStoreError

VERBS = {
    'profiles.get_asset': Verb('session:read', named=('name',)),
    'profiles.template.export': Verb('session:read', named=('name',)),
    'profiles.create': Verb('session:control', install_wide=True),
    'profiles.configure': Verb('session:control', named=('name',)),
    'profiles.set_asset': Verb('session:control', named=('name',)),
    'profiles.rename': Verb('session:control', install_wide=True),
    'profiles.delete': Verb('session:control', install_wide=True),
}


async def set_primary(connection, ref, params):
    from tui_gateway.contracts.canonical_bridge import ProfilesSetPrimaryParams
    authorize_profile(connection, params, 'session:control')
    if not administers_install(connection):
        raise RuntimeStoreError('permission_denied', field='profile', detail='this bot cannot manage the install')
    try:
        request = ProfilesSetPrimaryParams.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc
    from hermes_cli.primary_profile import set_primary_profile
    try:
        name = await asyncio.to_thread(set_primary_profile, request.name)
    except ValueError as exc:
        raise RuntimeStoreError('invalid_params', field='name') from exc
    except FileNotFoundError as exc:
        raise RuntimeStoreError('not_found', field='name') from exc
    except OSError as exc:
        raise RuntimeStoreError('storage_unavailable') from exc
    return {'ok': True, 'name': name}


def handlers(connection):
    return {**bridged(connection, VERBS), 'profiles.set_primary': partial(set_primary, connection)}
