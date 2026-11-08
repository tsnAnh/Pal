import pytest
import pytest_asyncio

from tests.gateway.bots_harness import FULL, READ, bots_state, call, failure, install_state
from tools.bot_desktop import lease as bot_lease

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


def ask_for_help(home):
    bot_lease.request_handback('sign in to the shared account', profile_key=str(home))
    return bot_lease.get(str(home))


@pytest.mark.asyncio
async def test_a_control_grant_ends_the_bots_pending_ask_on_the_native_socket(bots):
    pending = ask_for_help(bots.root)
    response = await call(bots.connect(capabilities=FULL), 'display.lease.resolve', {'ask_at': pending.ask_at})
    assert 'error' not in response, response
    assert response['result']['lease']['ask'] == ''
    assert bot_lease.get(str(bots.root)).ask == ''


@pytest.mark.asyncio
async def test_a_read_only_grant_cannot_end_the_ask(bots):
    pending = ask_for_help(bots.root)
    response = await call(bots.connect(capabilities=READ), 'display.lease.resolve', {})
    assert failure(response)['message'] == 'permission_denied'
    assert bot_lease.get(str(bots.root)).ask_at == pending.ask_at


@pytest.mark.asyncio
async def test_a_late_resolve_for_an_older_ask_leaves_the_newer_one(bots):
    older = ask_for_help(bots.root)
    newer = ask_for_help(bots.root)
    assert newer.ask_at != older.ask_at
    response = await call(bots.connect(capabilities=FULL), 'display.lease.resolve', {'ask_at': older.ask_at})
    assert 'error' not in response, response
    assert bot_lease.get(str(bots.root)).ask_at == newer.ask_at
