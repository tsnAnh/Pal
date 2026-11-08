import asyncio
import json
import os
from pathlib import Path

from tests.gateway.fixtures.local_recovery_probe import child_env, daemon, rpc, websocket

ROOT = Path(__file__).resolve().parents[2]
DEVICE_ID = 'e2e-canonical-phone-0001'


class Transcript:
    def __init__(self, ws):
        self.ws, self.entries = ws, []

    async def call(self, method, **params):
        reply = await rpc(self.ws, method, **params)
        self.entries.append({'method': method, 'params': params, 'reply': {
            key: reply[key] for key in ('result', 'error') if key in reply}})
        return reply


async def flow(home, desc):
    async with websocket(home, desc) as ws:
        wire = Transcript(ws)
        hello = await wire.call('client.hello', kind='ios', device_id=DEVICE_ID, label='E2E iPhone',
                                app_version='1.0', model='iPhone 16', os='iOS 26.1', accepts_offers=False,
                                device_tools=False, attention='foreground')
        assert hello['result']['recorded'] is True, hello
        devices = await wire.call('devices.list')
        assert [row['device_id'] for row in devices['result']['devices']] == [DEVICE_ID]
        assert devices['result']['devices'][0]['this_device'] is True

        subscriptions = await wire.call('account.subscriptions')
        assert subscriptions['result'] == {'subscriptions': []}, subscriptions
        library = await wire.call('library.list')
        assert library['result']['items'] == [] and library['result']['index_complete'] is True, library
        permissions = await wire.call('permissions.get')
        assert permissions['result']['auto_review'] is True, permissions
        await wire.call('permissions.set_auto_review', enabled=False)
        assert (await wire.call('permissions.get'))['result']['auto_review'] is False
        routines = await wire.call('cron.manage', action='list')
        assert routines['result']['success'] is True, routines
        refused = await wire.call('cron.manage', action='trigger_issue', name='x')
        assert refused['error']['code'] == 4001 and refused['error']['data']['field'] == 'action', refused
        unknown_key = await wire.call('permissions.get', bogus=True)
        assert unknown_key['error']['code'] == 4001 and 'bogus' in unknown_key['error']['data']['fields']

        before = await wire.call('profiles.list', include_sessions=False)
        assert [row['name'] for row in before['result']['profiles'] if row['is_primary']] == ['default']
        chosen = await wire.call('profiles.set_primary', name='alpha')
        assert chosen['result'] == {'ok': True, 'name': 'alpha'}, chosen
        after = await wire.call('profiles.list', include_sessions=False)
        assert [row['name'] for row in after['result']['profiles'] if row['is_primary']] == ['alpha']
        ghost = await wire.call('profiles.set_primary', name='ghost')
        assert ghost['error']['message'] == 'not_found', ghost
        deleted = await wire.call('profiles.delete', name='alpha')
        assert deleted['error']['code'] == 4102 and 'primary' in deleted['error']['message'], deleted
        return wire.entries


def prepare(tmp_path):
    from hermes_cli.profiles import create_profile
    home, user = tmp_path / 'state', tmp_path / 'user'
    home.mkdir(mode=0o700)
    user.mkdir()
    (home / 'config.yaml').write_text(json.dumps({
        'gateway': {'multiplex_profiles': False}, 'terminal': {'cwd': str(home)}}))
    previous = os.environ.get('HERMES_HOME')
    os.environ['HERMES_HOME'] = str(home)
    try:
        create_profile('alpha', no_alias=True, no_skills=True)
    finally:
        if previous is None:
            os.environ.pop('HERMES_HOME')
        else:
            os.environ['HERMES_HOME'] = previous
    env = child_env() | dict(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(ROOT),
                             PYTHONUNBUFFERED='1')
    return home, env


def run(home, env):
    with daemon(ROOT, home, env, barrier=False) as (_proc, desc):
        return asyncio.run(flow(home, desc))


def test_the_native_socket_of_a_real_daemon_serves_the_ios_app_rpcs(tmp_path):
    home, env = prepare(tmp_path)
    entries = run(home, env)
    assert len(entries) >= 14
    assert not any(entry['reply'].get('error', {}).get('code') == -32601 for entry in entries)
