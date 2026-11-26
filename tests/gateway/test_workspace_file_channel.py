import base64

import pytest
import pytest_asyncio

from gateway.session_timeline import load_timeline, page
from hermes_cli.profiles import get_profile_dir
from hermes_state import SessionDB
from tests.gateway.bots_harness import READ, bots_state, call, failure, install_state
from tui_gateway.contracts.registry import CANONICAL_METHODS

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


@pytest.mark.asyncio
async def test_a_timeline_ref_opens_over_the_authenticated_channel_for_its_own_bot_only(bots, tmp_path):
    home = get_profile_dir('alpha')
    note = home / 'workspace' / 'plan.md'
    note.write_text('# Plan\n', encoding='utf-8')
    store = SessionDB(tmp_path / 'timeline.db')
    store.create_session('s1', source='tui')
    store.append_message('s1', 'user', f'where is {note}')
    store.append_message('s1', 'assistant', f'It is at {note}')
    try:
        reply = page(load_timeline(str(home), store, 's1', str(home)), None, 10)
    finally:
        store.close()
    CANONICAL_METHODS['session.timeline'].result.model_validate(reply)
    asked, answered = reply['entries']
    assert 'file_refs' not in asked
    [found] = answered['file_refs']
    assert found['name'] == 'plan.md'

    served = await call(bots.connect('alpha', capabilities=READ), 'workspace.file', {'ref': found['ref']})
    assert base64.b64decode(served['result']['data_base64']) == b'# Plan\n', served
    CANONICAL_METHODS['workspace.file'].result.model_validate(served['result'])

    other = await call(bots.connect('beta', capabilities=READ), 'workspace.file', {'ref': found['ref']})
    assert failure(other, 4151)
    reach = await call(bots.connect('beta', capabilities=READ), 'workspace.file',
                       {'ref': found['ref'], 'profile': 'alpha'})
    assert failure(reach)['message'] == 'profile_mismatch'
    ungranted = await call(bots.connect('alpha', capabilities=['session:control']), 'workspace.file',
                           {'ref': found['ref']})
    assert failure(ungranted)['message'] == 'permission_denied'
    surprise = await call(bots.connect('alpha'), 'workspace.file', {'ref': found['ref'], 'path': str(note)})
    assert failure(surprise)['data']['reason'] == 'invalid_params'
