import sqlite3

import pytest
import pytest_asyncio

from tests.gateway.bots_harness import bots_state, install_state
from tests.gateway.devices_harness import call

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


@pytest.fixture
def kanban(tmp_path, monkeypatch):
    from hermes_cli import kanban_db as kb
    from hermes_cli import kanban_db_connect as kbc
    monkeypatch.setenv('HERMES_KANBAN_HOME', str(tmp_path / 'kanban-home'))
    kb.init_db()
    with kbc.connect_closing() as conn:
        kb.create_task(conn, title='card')
    return kb


async def boards_list(bots, **params):
    connection = bots.connect('default', host=True)
    connection.native_owner = True
    return await call(connection, 'kanban.boards.list', params)


def rows(response):
    assert 'error' not in response, response
    return {row['scope']['board']: row for row in response['result']['boards']}


def break_default(kb, how):
    path = kb.kanban_db_path()
    if how == 'missing_db':
        path.unlink()
    elif how == 'no_tasks_table':
        path.unlink()
        sqlite3.connect(path).close()
    else:
        path.write_bytes(b'not a database' * 100)


@pytest.mark.asyncio
async def test_a_readable_board_lists_with_counts_and_no_unavailable_reason(bots, kanban):
    answer = await boards_list(bots)
    default = rows(answer)['default']
    assert default['task_counts'] == {'ready': 1} and default['unavailable'] is None
    assert answer['result']['boards_seen'] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('how,reason', [('missing_db', 'absent'), ('no_tasks_table', 'absent'), ('garbage', 'unreadable')])
async def test_a_board_that_cannot_be_opened_is_listed_with_a_reason_not_dropped(bots, kanban, how, reason):
    break_default(kanban, how)
    answer = await boards_list(bots)
    default = rows(answer)['default']
    assert default['unavailable'] == reason and default['task_counts'] is None
    assert answer['result']['boards_seen'] == 1


@pytest.mark.asyncio
async def test_an_archived_board_keeps_its_row_without_a_reason(bots, kanban):
    kanban.create_board('old', name='Old')
    kanban.remove_board('old', archive=True)
    old = rows(await boards_list(bots))['old']
    assert old['archived'] is True and old['task_counts'] is None and old['unavailable'] is None


@pytest.mark.asyncio
async def test_a_stale_gateway_id_is_still_refused_and_the_cached_one_still_answers(bots, kanban):
    stale = await boards_list(bots, gateway_id='previous-run')
    assert stale['error']['data']['reason'] == 'gateway_mismatch', stale
    assert 'default' in rows(await boards_list(bots, gateway_id='owner'))
