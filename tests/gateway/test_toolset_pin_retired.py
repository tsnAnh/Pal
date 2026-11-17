"""profiles.configure ``enabled_toolsets`` is retired: another bot's ticket, a read-only grant and a worker
connection are still refused, and a full owner grant writes no pin."""

import pytest
import pytest_asyncio

from hermes_cli.profiles import get_profile_dir
from tests.gateway.bots_harness import FULL, READ, bots_state, call, config_of, failure, install_state

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)

PIN = {'name': 'beta', 'enabled_toolsets': ['web']}


@pytest.mark.asyncio
async def test_another_bots_ticket_cannot_pin_toolsets(bots):
    before = config_of(get_profile_dir('beta'))
    response = await call(bots.connect('alpha'), 'profiles.configure', PIN)
    assert failure(response)['message'] == 'profile_mismatch'
    assert config_of(get_profile_dir('beta')) == before


@pytest.mark.asyncio
@pytest.mark.parametrize('capabilities', [READ, ['worker:adopt']])
async def test_read_only_and_worker_grants_cannot_pin_toolsets(bots, capabilities):
    before = config_of(get_profile_dir('beta'))
    response = await call(bots.connect(capabilities=capabilities), 'profiles.configure', PIN)
    assert failure(response)['message'] == 'permission_denied'
    assert config_of(get_profile_dir('beta')) == before


@pytest.mark.asyncio
async def test_a_full_owner_grant_writes_no_toolset_pin(bots):
    before = config_of(get_profile_dir('beta'))
    response = await call(bots.connect(capabilities=FULL), 'profiles.configure', PIN)
    assert 'error' not in response, response
    assert config_of(get_profile_dir('beta')) == before
    assert 'platform_toolsets' not in config_of(get_profile_dir('beta'))
