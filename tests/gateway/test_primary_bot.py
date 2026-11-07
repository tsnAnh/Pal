import shutil

import pytest

from hermes_cli.primary_profile import primary_profile_name, set_primary_profile
from hermes_cli.profiles import create_profile, get_profile_dir
from tests.gateway.bots_harness import bots, call, config_of, install
from tui_gateway import server
from tui_gateway.contracts.registry import CANONICAL_METHODS


def legacy(method, **params):
    return server._methods[method](1, params)


@pytest.mark.asyncio
async def test_the_roster_flags_exactly_one_primary_and_follows_the_pointer(bots):
    connection = bots.connect()

    def primaries(response):
        assert 'error' not in response, response
        return [row['name'] for row in response['result']['profiles'] if row['is_primary']]

    assert primaries(await call(connection, 'profiles.list', {'include_sessions': False})) == ['default']
    set_primary_profile('Alpha')
    assert config_of(bots.root)['bot_mode']['primary_profile'] == 'alpha'
    assert 'primary_profile' not in (get_profile_dir('alpha') / 'config.yaml').read_text(encoding='utf-8')
    assert primaries(await call(connection, 'profiles.list', {'include_sessions': False})) == ['alpha']


@pytest.mark.asyncio
async def test_the_roster_counts_routines_on_request_and_reports_about_you_support(bots):
    connection = bots.connect()
    plain = await call(connection, 'profiles.list', {'include_sessions': False})
    assert 'error' not in plain, plain
    assert plain['result']['bot_about_you'] is True
    assert all('routines_enabled' not in row for row in plain['result']['profiles'])
    counted = await call(connection, 'profiles.list', {'include_sessions': False, 'include_routines': True})
    assert all(row['routines_enabled'] == 0 for row in counted['result']['profiles'])
    CANONICAL_METHODS['profiles.list'].result.model_validate(counted['result'])


def test_the_primary_bot_is_never_deleted_and_a_rename_carries_the_pointer(install):
    set_primary_profile('alpha')
    refused = legacy('profiles.delete', name='alpha')
    assert refused['error']['code'] == 4102 and 'primary' in refused['error']['message']
    assert get_profile_dir('alpha').is_dir()

    set_primary_profile('beta')
    assert legacy('profiles.delete', name='alpha')['result']['ok'] is True
    assert not get_profile_dir('alpha').exists()

    create_profile('gamma', no_alias=True, no_skills=True)
    set_primary_profile('gamma')
    assert legacy('profiles.rename', name='gamma', new_name='ranger')['result']['name'] == 'ranger'
    assert primary_profile_name() == 'ranger'


def test_a_pointer_at_a_missing_bot_reads_as_the_default_bot_and_a_missing_bot_cannot_be_chosen(install):
    set_primary_profile('beta')
    assert primary_profile_name() == 'beta'
    shutil.rmtree(get_profile_dir('beta'))
    assert primary_profile_name() == 'default'
    with pytest.raises(FileNotFoundError):
        set_primary_profile('beta')
    with pytest.raises(ValueError):
        set_primary_profile('  ')
    assert config_of(install)['bot_mode']['primary_profile'] == 'beta'
