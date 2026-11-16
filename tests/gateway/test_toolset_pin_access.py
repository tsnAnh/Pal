"""Pinning a bot's toolsets (profiles.configure enabled_toolsets) is reachable only by a grant that may
control that bot: another bot's ticket, a read-only grant and a worker connection are refused, and the
pin is untouched."""

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
async def test_a_full_owner_grant_pins_the_toolsets_in_that_bots_config_only(bots):
    pinned = await call(bots.connect(capabilities=FULL), 'profiles.configure', PIN)
    assert 'error' not in pinned, pinned
    assert config_of(get_profile_dir('beta'))['platform_toolsets']['cli'] == ['web']
    assert 'platform_toolsets' not in config_of(get_profile_dir('alpha'))
