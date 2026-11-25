import textwrap
from types import SimpleNamespace

import pytest

import hermes_cli.config as hermes_config
from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner

pytestmark = pytest.mark.usefixtures('authority_cwd_in_tmp')
MANAGED = textwrap.dedent("""\
    ui_meta:
      hermes-bots:
        shape: cloud
""")


@pytest.fixture
def managed(tmp_path, monkeypatch):
    home = tmp_path / 'home'
    home.mkdir()
    (home / 'profile.yaml').write_text(MANAGED, encoding='utf-8')
    hermes_config._LOAD_CONFIG_CACHE.clear()
    store, _runner, authority, connection = _owner(home, monkeypatch, {'model': {'default': 'm'}})
    yield SimpleNamespace(tmp=tmp_path, home=home, authority=authority, connection=connection)
    hermes_config._LOAD_CONFIG_CACHE.clear()
    store.close_all_db_handles()


@pytest.mark.asyncio
async def test_a_managed_profile_lists_no_approvals_even_with_old_held_files_on_disk(managed):
    live, _ = await _create(managed.connection, managed.authority, 'one', managed.tmp, source='ios')
    sid = next(key for key, candidate in managed.authority.sessions.items() if candidate is live)
    pending = managed.home / 'bot_mode' / 'drafts' / 'pending'
    pending.mkdir(parents=True)
    (pending / ('a' * 32 + '.json')).write_text(
        '{"id": "%s", "state": "pending", "tool": "connectors__gmail__SEND_EMAIL", "args": {"body": "hi"}}' % ('a' * 32),
        encoding='utf-8')
    reply = await managed.connection.dispatch(
        {'id': 'p', 'method': 'approval.pending', 'params': {'session_id': sid}})
    assert reply['result'] == {'approvals': []}
