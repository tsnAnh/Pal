import asyncio
import json
import logging
import re
from pathlib import Path

import pytest
import hermes_yaml as yaml

from gateway import auth_flows, auth_prompts
from hermes_cli import mcp_catalog
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tools import auth_required
from tools.registry import tool_error

pytest_plugins = ('tests.gateway.device_tools_harness',)
REPO = Path(__file__).resolve().parents[2]
KEY = 'sk-test-7d41aa90c3'


@pytest.fixture(autouse=True)
def clean_registry():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


def _reauth(server: str) -> str:
    return tool_error('MCP server needs re-authentication.', needs_reauth=True, server=server)


def _servers(monkeypatch, servers: dict) -> None:
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers', lambda config=None: servers)


async def _raise_and_decline(authority, phone, result: str):
    before = len(_required(phone))
    task = asyncio.ensure_future(_in_home(
        home_of(authority), lambda: auth_required.resolve('mcp_x_tool', {}, result, lambda: result)))
    await _wait_for(lambda: len(_required(phone)) == before + 1)
    event = _required(phone)[-1]
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task
    return event


def test_every_catalog_manifest_declares_its_auth_type_in_data():
    manifests = sorted((REPO / 'optional-mcps').glob('*/manifest.yaml'))
    assert manifests
    for path in manifests:
        auth = (yaml.safe_load(path.read_text()) or {}).get('auth')
        assert isinstance(auth, dict) and auth.get('type') in auth_required.AUTH_TYPES, f'{path.parent.name}: no auth.type'
    assert len(mcp_catalog.list_catalog()) == len(manifests), 'a manifest failed to parse'


@pytest.mark.asyncio
async def test_every_catalog_connector_that_needs_auth_can_raise_the_sign_in_event(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    flows = {'oauth': 'oauth', 'api_key': 'api_key'}
    checked = 0
    for entry in mcp_catalog.list_catalog():
        declared = auth_required.declared_auth_type(entry)
        if declared == 'none':
            continue
        _servers(monkeypatch, {entry.name: mcp_catalog._build_server_config(entry, None)})
        event = await _raise_and_decline(authority, phone, _reauth(entry.name))
        assert event['flow'] == flows[declared], entry.name
        assert event['service'] == f'mcp:{entry.name}' and event['service_name'].strip(), entry.name
        assert event['bot'] == 'default' and event.get('server') in (None, entry.name)
        checked += 1
    assert checked >= 50


def test_an_entry_without_a_usable_auth_type_is_rejected():
    class Auth:
        type = None

    class Entry:
        name = 'broken'
        auth = Auth()

    with pytest.raises(ValueError):
        auth_required.declared_auth_type(Entry())
    Auth.type = 'basic'
    with pytest.raises(ValueError):
        auth_required.declared_auth_type(Entry())


@pytest.mark.parametrize('cfg,flow', [
    ({'url': 'https://x.example/mcp', 'auth': 'oauth'}, 'oauth'),
    ({'url': 'https://x.example/mcp'}, 'oauth'),
    ({'url': 'https://x.example/mcp', 'headers': {'Authorization': 'Bearer ${MCP_X_API_KEY}'}}, 'api_key'),
    ({'url': 'https://x.example/mcp', 'headers': {'X-Api-Token': '${T}'}}, 'header'),
    ({'url': 'https://x.example/mcp', 'headers': {'Authorization': 'Bearer ${A}', 'X-Org': '1'}}, 'header'),
    ({'command': 'x', 'env': {'K': '${K}'}}, 'manual'),
])
def test_custom_connector_credentials_map_to_the_right_flow(cfg, flow):
    assert auth_flows.classify_mcp_server(cfg) == flow


@pytest.mark.asyncio
async def test_api_key_connector_takes_the_key_through_the_existing_secret_path(authorities, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    stored = {}
    monkeypatch.setattr('hermes_cli.config.get_env_value', lambda name: stored.get(name))
    _servers(monkeypatch, {'acme': {'url': 'https://acme.example/mcp',
                                    'headers': {'Authorization': 'Bearer ${MCP_ACME_API_KEY}'}}})
    retries = []

    def retry():
        retries.append(1)
        return json.dumps({'ok': True})

    task = asyncio.ensure_future(_in_home(
        home_of(authority), lambda: auth_required.resolve('mcp_acme_x', {}, _reauth('acme'), retry)))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['flow'] == 'api_key' and event['server'] == 'acme'
    assert (await phone.call('auth.signin', {'request_id': event['request_id']}))['result']['recorded'] is False
    stored['MCP_ACME_API_KEY'] = KEY
    assert (await phone.call('auth.signin', {'request_id': event['request_id']}))['result']['recorded'] is True
    assert json.loads(await task) == {'ok': True} and retries == [1]
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert KEY not in json.dumps(phone.frames) + caplog.text


@pytest.mark.asyncio
async def test_rejected_custom_header_raises_a_header_event_without_an_in_app_signin(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    _servers(monkeypatch, {'acme': {'url': 'https://acme.example/mcp', 'headers': {'X-Api-Token': '${T}'}}})
    event = await _raise_and_decline(authority, phone, _reauth('acme'))
    assert event['flow'] == 'header' and event['server'] == 'acme'


class FakePortal:
    def __init__(self):
        self.connected = False
        self.minted = []

    def connections(self, names, **kwargs):
        self.minted.append(names)
        return {'results': [{'connector': names[0], 'status': 'initiated',
                             'connect_url': 'https://portal.example/connect/abc'}]}

    def list_connectors(self):
        return [{'connector': 'slack', 'connected': self.connected, 'connection_status': 'active'}]


@pytest.mark.asyncio
async def test_hosted_connector_oauth_opens_the_portal_link_then_retries_when_connected(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    portal = FakePortal()
    monkeypatch.setattr('tools.connectors.managed.managed_client', lambda **kwargs: portal)
    monkeypatch.setattr(auth_flows.HostedConnectorFlow, 'POLL_SECONDS', 0.05)
    expired = json.dumps({'error': {'code': 'CONNECTION_EXPIRED', 'connector': 'Slack', 'message': 'expired'}})
    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'connectors__slack__post', {}, expired, lambda: json.dumps({'response': 'sent'}))))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['service'] == 'connector:slack' and event['service_name'] == 'Slack'
    assert event['flow'] == 'oauth' and event['reason'] == 'expired'
    reply = await phone.call('auth.signin', {'request_id': event['request_id']})
    assert reply['result'] == {'recorded': True, 'authorization_url': 'https://portal.example/connect/abc'}
    portal.connected = True
    assert json.loads(await task) == {'response': 'sent'}


def test_hosted_codes_are_detected_at_top_level_and_in_the_error_envelope():
    body = {'code': 'CONNECTION_REQUIRED', 'connector': 'notion'}
    assert auth_required.detect('t', {}, json.dumps(body)).service == 'connector:notion'
    assert auth_required.detect('t', {}, json.dumps({'error': body})).reason == 'missing'
    assert auth_required.detect('t', {}, json.dumps({'error': {'code': 'PROVIDER_ERROR', 'connector': 'x'}})) is None


def _swift_cases(path: Path, enum: str) -> set[str]:
    text = path.read_text()
    block = re.search(rf'enum {enum}\b[^{{]*\{{(.*?)\n\}}', text, re.DOTALL).group(1)
    cases = set()
    for line in block.splitlines():
        found = re.match(r'\s*case (\w+)(?: = "([^"]+)")?\s*$', line)
        if found:
            cases.add(found.group(2) or found.group(1))
    return cases - {'unknown'}


def test_swift_wire_values_match_the_gateway_contract():
    from tui_gateway.contracts.canonical_auth import AuthCredentialOutcome, AuthFlow, AuthOutcome, AuthReason
    wire = REPO / 'apps/ios/Packages/PalKit/Sources/PalProtocol/ServiceSignInWire.swift'
    assert _swift_cases(wire, 'ServiceSignInFlow') == {item.value for item in AuthFlow}
    assert _swift_cases(wire, 'ServiceSignInReason') == {item.value for item in AuthReason}
    assert _swift_cases(wire, 'ServiceSignInOutcome') == {item.value for item in AuthOutcome}
    assert _swift_cases(wire, 'AuthCredentialOutcome') == {item.value for item in AuthCredentialOutcome}


def test_every_connect_app_source_in_swift_has_a_declared_sign_in_flow():
    catalog = REPO / 'apps/ios/Packages/PalKit/Sources/PalConnect/ConnectCatalog.swift'
    block = re.search(r'enum ConnectAppSource\b[^{]*\{(.*?)\n\}', catalog.read_text(), re.DOTALL).group(1)
    sources = set(re.findall(r'^\s*case (\w+)', block, re.MULTILINE))
    assert sources == set(auth_flows.CONNECT_APP_SOURCES), 'declare the new Connected apps source in auth_flows'
