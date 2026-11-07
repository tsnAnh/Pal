from pathlib import Path
from types import SimpleNamespace

import pytest
import pytest_asyncio

import hermes_cli.config as hermes_config
import hermes_yaml as yaml
from gateway.session_authorities import SessionAuthorities
from gateway.session_controls import AuthorityConnection
from hermes_cli.profiles import create_profile, get_profile_dir
from hermes_state import SessionDB
from tests.gateway.devices_harness import call, make_authority, transport, write_profile_config
from tui_gateway import server

READ = ['session:read']
FULL = ['session:read', 'session:control', 'session:submit', 'session:create']


@pytest.fixture
def install(tmp_path, monkeypatch):
    root = tmp_path / 'state'
    root.mkdir()
    monkeypatch.setenv('HERMES_HOME', str(root))
    monkeypatch.setattr(server, '_hermes_home', root)
    write_profile_config(root, 'model:\n  default: launch-model\n')
    create_profile('alpha', no_alias=True, no_skills=True)
    create_profile('beta', no_alias=True, no_skills=True)
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()
    yield root
    server._drop_cfg_cache()
    hermes_config._LOAD_CONFIG_CACHE.clear()


@pytest_asyncio.fixture
async def bots(install):
    runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=False),
                             session_authorities=SessionAuthorities(install, multiplexed=True))
    authorities = {}
    for name, home in (('default', install), ('alpha', get_profile_dir('alpha')), ('beta', get_profile_dir('beta'))):
        authorities[name] = await make_authority(home, runner, register=False)
        authorities[name].db = SessionDB(db_path=home / 'state.db')
        runner.session_authorities.add(home, authorities[name], name)
    opened = []

    def connect(bot='default', *, capabilities=FULL, host=False):
        identity = {'user_id': 'owner', 'capabilities': capabilities}
        if host:
            identity['profile_scope'] = 'host'
        connection = AuthorityConnection(authorities[bot], transport(), identity)
        opened.append(connection)
        return connection

    yield SimpleNamespace(connect=connect, root=install)
    for connection in opened:
        await connection.close()
    for authority in authorities.values():
        authority.db.close()


def config_of(home: Path) -> dict:
    path = home / 'config.yaml'
    return (yaml.safe_load(path.read_text(encoding='utf-8')) if path.is_file() else None) or {}


def failure(response, code=4001):
    assert response['error']['code'] == code, response
    return response['error']


