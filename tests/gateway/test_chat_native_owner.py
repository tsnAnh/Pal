import pytest
import pytest_asyncio

from tests.gateway.bots_harness import FULL, READ, bots_state, install_state
from tests.gateway.devices_harness import call
from tui_gateway.contracts.registry import CANONICAL_METHODS
from tui_gateway.contracts.canonical_bridge import BRIDGED

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)

SWIFT_CALLS = [
    ('chat.provider.list', {'profile': 'alpha'}),
    ('chat.install.status', {'profile': 'alpha', 'provider_id': 'slack', 'workspace': ''}),
    ('chat.spaces.list', {'profile': 'alpha', 'provider_id': 'slack', 'workspace': ''}),
    ('chat.binding.list', {'profile': 'alpha', 'provider_id': 'slack', 'workspace': ''}),
]


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params', SWIFT_CALLS[:2])
async def test_the_owners_host_socket_reads_a_bots_chat_setup(bots, method, params):
    response = await call(bots.connect('default', host=True), method, params)
    assert 'error' not in response, response
    CANONICAL_METHODS[method].result.model_validate(response['result'])


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params', SWIFT_CALLS[:2])
async def test_a_bots_own_ticket_is_still_refused_the_chat_setup(bots, method, params):
    response = await call(bots.connect('alpha'), method, params)
    assert response['error']['data']['reason'] == 'owner_only', response


@pytest.mark.asyncio
async def test_update_identity_is_served_on_the_native_socket_as_a_control_verb(bots):
    params = {'profile': 'alpha', 'provider_id': 'slack', 'workspace': ''}
    assert 'chat.install.update_identity' in BRIDGED
    denied = await call(bots.connect('default', host=True, capabilities=READ), 'chat.install.update_identity', params)
    assert denied['error']['message'] == 'permission_denied', denied
    served = await call(bots.connect('default', host=True, capabilities=FULL), 'chat.install.update_identity', params)
    assert served['error']['data']['reason'] == 'no_installation', served
