"""vault.* through the real daemon websocket: every item kind, per-bot profile isolation, scope enforcement,
and no secret in any response, error, log line or ``browser_vault`` listing."""
import asyncio
import json
import logging
import os
from pathlib import Path

import pytest
import pytest_asyncio

from agent.vault_store import VaultStore
from tests.gateway.bots_harness import FULL, READ, bots_state, call, failure, install_state
from tests.gateway.fixtures.local_recovery_probe import child_env, control, daemon, rpc
from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parents[2]
PASSWORD = "test-pw-do-not-use"
KEY = "test-key-do-not-use"
HELLO = dict(kind='ios', device_id='vault-e2e-phone-0001', label='E2E', app_version='1.0', model='iPhone',
             os='iOS', accepts_offers=False, device_tools=False, attention='foreground')

CASES = {
    'login': dict(
        add=dict(kind='login', label='Example', origin='https://example.com',
                 secret={'identifier_type': 'email', 'identifier': 'a@example.com', 'password': PASSWORD}),
        keep={'password': ''}, kept={'password': PASSWORD},
        replace={'password': KEY, 'identifier': 'b@example.com'}, replaced={'password': KEY}),
    'payment': dict(
        add=dict(kind='payment', label='Visa', origin='https://shop.example',
                 secret={'card_number': PASSWORD, 'exp_month': '07', 'exp_year': '2030', 'cvc': KEY}),
        keep={'card_number': '', 'cvc': ''}, kept={'card_number': PASSWORD, 'exp_month': '07', 'exp_year': '2030', 'cvc': KEY},
        replace={'cvc': PASSWORD}, replaced={'card_number': PASSWORD, 'exp_month': '07', 'exp_year': '2030', 'cvc': PASSWORD}),
    'address': dict(
        add=dict(kind='address', label='Home',
                 secret={'address_line1': '1 Main St', 'city': 'Hanoi', 'postal_code': '10000', 'country': 'Vietnam'}),
        keep={'city': ''}, kept={'address_line1': '1 Main St', 'city': 'Hanoi', 'postal_code': '10000', 'country': 'Vietnam'},
        replace={'city': 'Da Nang'}, replaced={'address_line1': '1 Main St', 'city': 'Da Nang', 'postal_code': '10000', 'country': 'Vietnam'}),
    'api_key': dict(
        add=dict(kind='api_key', label='OpenAI', secret={'api_key': KEY}),
        keep={'api_key': ''}, kept={'api_key': KEY},
        replace={'api_key': PASSWORD}, replaced={'api_key': PASSWORD}),
}


def socket_for(home, profile_home, desc, scope=None):
    grant = control(home, 'session-ticket', {'profile_id': str(profile_home), 'instance_id': desc['instance_id'],
                                             'purpose': 'interactive', **({'scope': scope} if scope else {})})
    return connect(desc['api_origin'].replace('http:', 'ws:') + '/api/ws',
                   subprotocols=['hermes-gateway-v1', 'hermes-gateway-ticket.' + grant['ticket']])


def prepare(tmp_path):
    from hermes_cli.profiles import create_profile, get_profile_dir
    home, user = tmp_path / 'state', tmp_path / 'user'
    home.mkdir(mode=0o700)
    user.mkdir()
    (home / 'config.yaml').write_text(json.dumps({'gateway': {'multiplex_profiles': False}, 'terminal': {'cwd': str(home)}}))
    previous = os.environ.get('HERMES_HOME')
    os.environ['HERMES_HOME'] = str(home)
    try:
        create_profile('alpha', no_alias=True, no_skills=True)
        alpha = get_profile_dir('alpha')
    finally:
        if previous is None:
            os.environ.pop('HERMES_HOME')
        else:
            os.environ['HERMES_HOME'] = previous
    env = child_env() | dict(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(ROOT),
                             PYTHONUNBUFFERED='1')
    return home, alpha, env


@pytest.fixture(scope='module')
def served(tmp_path_factory):
    home, alpha, env = prepare(tmp_path_factory.mktemp('vault-e2e'))
    with daemon(ROOT, home, env, barrier=False) as (_proc, desc):
        yield home, alpha, desc


def session(served):
    home, _alpha, desc = served

    async def run(script):
        async with socket_for(home, home, desc, 'host') as ws:
            await rpc(ws, 'client.hello', **HELLO)
            return await script(ws)
    return lambda script: asyncio.run(run(script))


def store(alpha):
    return VaultStore(alpha / 'vault')


@pytest.mark.parametrize('kind', list(CASES))
def test_add_list_update_remove_every_kind_on_a_non_launch_profile(served, kind):
    _home, alpha, _desc = served
    case, vault = CASES[kind], store(alpha)

    async def script(ws):
        out = {}
        added = out['add'] = await rpc(ws, 'vault.add', profile='alpha', **case['add'])
        item_id = added['result']['id']
        out['list'] = await rpc(ws, 'vault.list', profile='alpha')
        out['rename'] = await rpc(ws, 'vault.update', profile='alpha', id=item_id, label='Renamed', secret=case['keep'])
        out['after_keep'] = vault.resolve_secret(item_id)
        out['replace'] = await rpc(ws, 'vault.update', profile='alpha', id=item_id, secret=case['replace'])
        out['after_replace'] = vault.resolve_secret(item_id)
        out['kind_param'] = await rpc(ws, 'vault.update', profile='alpha', id=item_id, kind='payment', label='Still ' + kind)
        out['kind_after'] = vault.get_meta(item_id).kind
        out['remove'] = await rpc(ws, 'vault.remove', profile='alpha', id=item_id)
        out['remove_again'] = await rpc(ws, 'vault.remove', profile='alpha', id=item_id)
        out['list_after'] = await rpc(ws, 'vault.list', profile='alpha')
        out['id'] = item_id
        return out

    out = session(served)(script)
    listed = {i['id']: i for i in out['list']['result']['items']}[out['id']]
    assert listed['kind'] == kind and listed['label'] == case['add']['label'] and listed['backend'] == 'local'
    if kind == 'api_key':
        assert not listed.get('origin') and 'identifier' not in listed
    assert out['rename']['result']['label'] == 'Renamed' and out['rename']['result']['kind'] == kind
    assert out['after_keep'] == case['kept']
    assert out['replace']['result']['id'] == out['id']
    assert out['after_replace'] == case['replaced']
    assert out['kind_after'] == kind
    assert 'error' in out['kind_param'] or out['kind_param']['result']['kind'] == kind
    assert out['remove']['result'] == {'removed': True} and out['remove_again']['result'] == {'removed': False}
    assert out['id'] not in {i['id'] for i in out['list_after']['result']['items']}


def test_an_item_lives_only_in_the_profile_it_was_added_to(served):
    home, alpha, _desc = served

    async def script(ws):
        alpha_id = (await rpc(ws, 'vault.add', profile='alpha', kind='api_key', label='alpha-only', secret={'api_key': KEY}))['result']['id']
        default_id = (await rpc(ws, 'vault.add', profile='default', kind='api_key', label='default-only', secret={'api_key': PASSWORD}))['result']['id']
        ids = {name: {i['id'] for i in (await rpc(ws, 'vault.list', **({'profile': name} if name else {})))['result']['items']}
               for name in ('alpha', 'default', None)}
        crossed = await rpc(ws, 'vault.update', profile='default', id=alpha_id, label='hijack')
        await rpc(ws, 'vault.remove', profile='alpha', id=alpha_id)
        await rpc(ws, 'vault.remove', profile='default', id=default_id)
        return alpha_id, default_id, ids, crossed

    alpha_id, default_id, ids, crossed = session(served)(script)
    assert alpha_id in ids['alpha'] and default_id not in ids['alpha']
    assert default_id in ids['default'] and alpha_id not in ids['default']
    assert default_id in ids[None] and alpha_id not in ids[None]
    assert 'error' in crossed and 'hijack' not in {m.label for m in store(alpha).list_items()}
    assert (home / 'vault').exists() and (alpha / 'vault').exists()


install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


@pytest.mark.asyncio
@pytest.mark.parametrize('method,extra', [
    ('vault.add', {'kind': 'api_key', 'label': 'OpenAI', 'secret': {'api_key': KEY}}),
    ('vault.update', {'label': 'x'}),
    ('vault.remove', {}),
])
async def test_a_grant_without_control_cannot_change_the_vault(bots, method, extra):
    from hermes_cli.profiles import get_profile_dir

    vault = VaultStore(get_profile_dir('alpha') / 'vault')
    seeded = vault.add_item('api_key', 'seed', {'api_key': KEY})
    params = {'profile': 'alpha', **extra, **({'id': seeded.id} if method != 'vault.add' else {})}
    refused = failure(await call(bots.connect('alpha', capabilities=READ), method, params))
    assert refused['message'] == 'permission_denied'
    assert [(m.id, m.label) for m in vault.list_items()] == [(seeded.id, 'seed')]
    allowed = await call(bots.connect('alpha', capabilities=FULL), 'vault.list', {'profile': 'alpha'})
    assert 'error' not in allowed, allowed


def test_the_api_key_never_leaves_the_daemon_in_any_response_error_or_log(served, tmp_path, caplog):
    home, alpha, _desc = served

    async def script(ws):
        seen = []
        added = await rpc(ws, 'vault.add', profile='alpha', kind='api_key', label='leak-probe', secret={'api_key': KEY})
        item_id = added['result']['id']
        seen += [added, await rpc(ws, 'vault.list', profile='alpha'),
                 await rpc(ws, 'vault.update', profile='alpha', id=item_id, label='leak-probe 2', secret={'api_key': KEY}),
                 await rpc(ws, 'vault.sources', profile='alpha')]
        errors = [
            await rpc(ws, 'vault.add', profile='alpha', kind=KEY, label='x', secret={'api_key': KEY}),
            await rpc(ws, 'vault.add', profile='alpha', kind='payment', label='x', origin=KEY, secret={'card_number': KEY}),
            await rpc(ws, 'vault.add', profile='alpha', kind='api_key', label='x', secret={'api_key': KEY, 'password': PASSWORD}),
            await rpc(ws, 'vault.update', profile='alpha', id=KEY, secret={'api_key': KEY}),
            await rpc(ws, 'vault.update', profile='alpha', id=item_id, origin=KEY, secret={'api_key': KEY, KEY: KEY}),
        ]
        await rpc(ws, 'vault.remove', profile='alpha', id=item_id)
        return seen, errors

    seen, errors = session(served)(script)
    assert all('error' in e for e in errors), errors
    assert KEY not in json.dumps(seen + errors)

    from tools import browser_vault_tool
    from unittest.mock import patch
    store(alpha).add_item('api_key', 'listed', {'api_key': KEY})
    with caplog.at_level(logging.DEBUG), patch('agent.vault_store.get_vault_store', return_value=store(alpha)):
        listing = browser_vault_tool.browser_vault_list()
    assert 'listed' in listing and KEY not in listing and KEY not in caplog.text

    leaks = [str(p.relative_to(home)) for p in home.rglob('*')
             if p.is_file() and not p.name.startswith('vault.json') and KEY.encode() in p.read_bytes()]
    assert leaks == []
