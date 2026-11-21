"""Device sign-in for MCP vendors whose authorization server registers only loopback redirects.

Invariants: the gateway never starts its own flow for such a connector through the app or gateway redirect (the
vendor would refuse the registration) and says so with a typed reason; the hand-over of the device's tokens lands
per account and the connector then works from the gateway alone; a grant with no refresh token that has expired is
shown as needing sign-in everywhere, is never refreshed or re-registered, and a new hand-over clears it; connectors
the gateway signs in keep every one of those behaviours.
"""

import asyncio
import json
import threading
import time
from urllib.parse import parse_qs

import pytest
import uvicorn
from mcp.server import MCPServer
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from gateway import auth_prompts
from hermes_cli import mcp_catalog
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tests.waiting import wait_until
from tools import auth_required, mcp_oauth_import
from tools.mcp_oauth import HermesTokenStorage, OwnerSigninRequired, pending_reauth_reason
from tools.registry import tool_error
from tui_gateway import server as rpc

pytest_plugins = ('tests.gateway.device_tools_harness',)

VENDORS = {
    'circleci': 'https://mcp.circleci.com/v1/mcp',
    'gamma': 'https://mcp.gamma.app/mcp',
    'intercom': 'https://mcp.intercom.com/mcp',
    'vercel': 'https://mcp.vercel.com',
    'upwork': 'https://mcp.upwork.com/mcp',
}
APP_REDIRECT = 'dev.tsnanh.hermes.bot:/mcp-oauth/callback'
LOOPBACK = 'http://127.0.0.1:53682/callback'
ACCESS, REFRESH = 'at-canary-5c1e90ab77d2', 'rt-canary-1b84e0d6f9a3'


def handover(slug, *, service=None, refresh=REFRESH, access=ACCESS, **override):
    body = {
        'service': service or f'mcp:{slug}', 'client_id': 'client-abc', 'redirect_uri': LOOPBACK,
        'token_endpoint': f'https://auth.{slug}.example/token', 'issuer': f'https://auth.{slug}.example',
        'access_token': access, 'expires_in': 3600, 'token_type': 'Bearer'}
    if refresh:
        body['refresh_token'] = refresh
    return {**body, **override}


def call_rpc(home, method, params=None):
    def run():
        reply = rpc._methods[method](1, params or {})
        return reply
    return _in_home(home, run)


def token_dir(authority, slug):
    return home_of(authority) / 'mcp-tokens' / 'accounts' / slug


def expire_access_token(home, connection):
    storage = HermesTokenStorage(connection, hermes_home=home)
    path = storage._tokens_path()
    data = json.loads(path.read_text())
    data['expires_at'] = time.time() - 10
    path.write_text(json.dumps(data))


def row(catalog_reply, slug):
    return next(r for r in catalog_reply['result']['connectors'] if r['slug'] == slug)


@pytest.fixture(autouse=True)
def fresh_state():
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    yield
    reset_manager_for_tests()
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


@pytest.fixture
def no_flow(monkeypatch):
    started = []

    def worker(*args, **kwargs):
        started.append(kwargs['flow'].redirect_uri)
        kwargs['flow'].mark_error('stopped by the test')
        kwargs['flow'].mark_worker_done()
    monkeypatch.setattr('tui_gateway.mcp_oauth_sessions.run_worker', worker)
    return started


@pytest.mark.asyncio
@pytest.mark.parametrize('slug', sorted(VENDORS))
async def test_the_hand_over_lands_per_account_and_the_catalog_lists_both(authorities, slug):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)
    assert (await phone.call('auth.submit_oauth_tokens', handover(slug)))['result'] == {'ok': True}
    second = handover(slug, service=f'mcp:{slug}:work', access='at-second-account-77', refresh='rt-second-account-77')
    assert (await phone.call('auth.submit_oauth_tokens', second))['result'] == {'ok': True}
    folder = token_dir(authority, slug)
    stored = {name: json.loads((folder / name).read_text()) for name in ('default.json', 'work.json')}
    assert stored['default.json']['access_token'] == ACCESS and stored['work.json']['access_token'] == 'at-second-account-77'
    assert {p.name for p in folder.glob('*.client.json')} == {'default.client.json', 'work.client.json'}
    catalog = row(await call_rpc(home, 'connectors.catalog'), slug)
    assert catalog['sign_in'] == 'device' and catalog['mcp_url'] == VENDORS[slug]
    assert {a['name']: a['status'] for a in catalog['accounts']} == {'default': 'connected', 'work': 'connected'}


@pytest.mark.asyncio
@pytest.mark.parametrize('slug', sorted(set(VENDORS) - {'upwork'}))
@pytest.mark.parametrize('redirect', [APP_REDIRECT, None])
async def test_the_app_and_gateway_redirects_are_refused_before_any_registration(authorities, no_flow, slug, redirect):
    authority = await authorities('home')
    home = home_of(authority)
    added = await call_rpc(home, 'mcp.servers.add', {'name': slug, 'config': {'url': VENDORS[slug], 'transport': 'http'}})
    assert added['result']['ok'] is True
    params = {'name': slug}
    if redirect:
        params |= {'client_redirect_uri': redirect, 'fallback_redirect_uri': LOOPBACK}
    reply = await call_rpc(home, 'mcp.servers.oauth.start', params)
    assert reply['error']['code'] == 4034 and reply['error']['data'] == {'reason': 'SIGNIN_ON_DEVICE'}
    assert 'your own device' in reply['error']['message']
    assert no_flow == []


@pytest.mark.asyncio
async def test_a_sign_in_the_client_hosts_on_its_own_loopback_is_still_taken(authorities, no_flow):
    authority = await authorities('home')
    home = home_of(authority)
    await call_rpc(home, 'mcp.servers.add', {'name': 'circleci', 'config': {'url': VENDORS['circleci'], 'transport': 'http'}})
    reply = await call_rpc(home, 'mcp.servers.oauth.start', {'name': 'circleci', 'client_redirect_uri': LOOPBACK})
    assert reply['error']['code'] != 4034
    assert no_flow == [LOOPBACK]


@pytest.mark.asyncio
async def test_a_gateway_connector_keeps_its_app_redirect_chain(authorities, no_flow):
    authority = await authorities('home')
    home = home_of(authority)
    await call_rpc(home, 'mcp.servers.add', {'name': 'acme', 'config': {'url': 'https://mcp.acme.example/mcp', 'transport': 'http'}})
    reply = await call_rpc(home, 'mcp.servers.oauth.start', {'name': 'acme', 'client_redirect_uri': APP_REDIRECT, 'fallback_redirect_uri': LOOPBACK})
    assert reply.get('error', {}).get('code') != 4034
    assert no_flow and no_flow[0] == APP_REDIRECT


@pytest.mark.asyncio
@pytest.mark.parametrize('slug', sorted(set(VENDORS) - {'upwork'}))
async def test_a_lapsed_grant_with_no_refresh_token_needs_sign_in_everywhere(authorities, slug):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)
    assert (await phone.call('auth.submit_oauth_tokens', handover(slug, refresh=None)))['result'] == {'ok': True}
    assert row(await call_rpc(home, 'connectors.catalog'), slug)['status'] == 'connected'
    expire_access_token(home, f'{slug}@default')
    reason = f'Sign in again: {slug.title()} (default) stopped accepting the saved sign-in'
    catalog = row(await call_rpc(home, 'connectors.catalog'), slug)
    assert catalog['status'] == 'needs_reconnect'
    assert catalog['accounts'] == [{'name': 'default', 'status': 'needs_reconnect', 'reason': reason}]
    presets = (await call_rpc(home, 'mcp.catalog'))['result']['servers']
    assert next(p for p in presets if p['name'] == slug)['needs_auth_reason'] == reason


@pytest.mark.asyncio
async def test_a_lapsed_grant_is_never_refreshed_or_registered_again_and_a_new_hand_over_clears_it(authorities):
    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool import sdk_httpx
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)
    await phone.call('auth.submit_oauth_tokens', handover('circleci', refresh=None))
    expire_access_token(home, 'circleci@default')
    httpx, sent = sdk_httpx(), []

    async def first_request():
        provider = get_manager().get_or_build_provider('circleci@default', VENDORS['circleci'], {})
        flow = provider.async_auth_flow(httpx.Request('POST', VENDORS['circleci']))
        sent.append(await flow.__anext__())

    def stops_before_the_network():
        with pytest.raises(OwnerSigninRequired):
            asyncio.run(first_request())
    await _in_home(home, stops_before_the_network)
    assert sent == []
    assert await _in_home(home, lambda: pending_reauth_reason('circleci@default')) is not None
    fresh = handover('circleci', access='at-fresh-after-expiry-4411', refresh=None)
    assert (await phone.call('auth.submit_oauth_tokens', fresh))['result'] == {'ok': True}
    assert await _in_home(home, lambda: pending_reauth_reason('circleci@default')) is None
    assert row(await call_rpc(home, 'connectors.catalog'), 'circleci')['status'] == 'connected'


@pytest.mark.asyncio
async def test_a_connector_the_gateway_signs_in_is_flagged_for_the_same_lapse(authorities):
    from hermes_cli.mcp_config import _save_mcp_server
    authority = await authorities('home')
    home = home_of(authority)

    def lapse():
        assert _save_mcp_server('acme', {'url': 'https://mcp.acme.example/mcp', 'auth': 'oauth', 'enabled': True})
        storage = HermesTokenStorage('acme', hermes_home=home)
        storage._tokens_path().parent.mkdir(parents=True, exist_ok=True)
        storage._tokens_path().write_text(json.dumps({
            'access_token': ACCESS, 'token_type': 'Bearer', 'expires_at': time.time() - 10}))
        return pending_reauth_reason('acme'), storage.reauth_required()
    reason, flagged = await _in_home(home, lapse)
    assert reason and flagged is True


@pytest.mark.asyncio
async def test_a_bare_saved_entry_of_a_device_connector_raises_the_owner_computer_prompt(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    bare = {'circleci': {'url': VENDORS['circleci'], 'auth': 'oauth', 'enabled': True}}
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers', lambda config=None: bare)
    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'mcp_circleci_x', {}, tool_error('x', needs_reauth=True, server='circleci'), lambda: json.dumps({'ok': True}))))
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['flow'] == 'oauth' and event['signin_on'] == 'owner_app' and event['server'] == 'circleci'
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


class FakeVendor:
    """An authorization server that registers loopback redirects only, in front of a bearer-gated MCP server."""

    def __init__(self):
        self.registrations: list[list[str]] = []
        self.grants: list[str] = []
        self.valid: set[str] = set()
        mcp = MCPServer('fake-circleci')

        @mcp.tool()
        def list_pipelines(project: str) -> str:
            """List the pipelines of a project."""
            return f'pipelines:{project}'

        inner = mcp.streamable_http_app()
        as_app = Starlette(routes=[
            Route('/.well-known/oauth-protected-resource/{rest:path}', self._resource),
            Route('/.well-known/oauth-protected-resource', self._resource),
            Route('/.well-known/oauth-authorization-server', self._metadata),
            Route('/register', self._register, methods=['POST']),
            Route('/token', self._token, methods=['POST']),
        ])

        async def app(scope, receive, send):
            if scope['type'] == 'http' and scope['path'].startswith('/mcp'):
                bearer = dict(scope['headers']).get(b'authorization', b'').decode().removeprefix('Bearer ')
                if bearer not in self.valid:
                    await send({'type': 'http.response.start', 'status': 401, 'headers': [(b'content-type', b'application/json')]})
                    await send({'type': 'http.response.body', 'body': b'{"error":"invalid_token"}'})
                    return
                await inner(scope, receive, send)
            elif scope['type'] == 'lifespan':
                await inner(scope, receive, send)
            else:
                await as_app(scope, receive, send)

        self._server = uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=0, log_level='warning', lifespan='on'))
        self._thread = threading.Thread(target=self._server.run, daemon=True)

    @property
    def base(self):
        return f'http://127.0.0.1:{self._server.servers[0].sockets[0].getsockname()[1]}'

    @property
    def mcp_url(self):
        return f'{self.base}/mcp'

    async def _resource(self, request):
        return JSONResponse({'resource': self.mcp_url, 'authorization_servers': [self.base]})

    async def _metadata(self, request):
        return JSONResponse({
            'issuer': self.base, 'authorization_endpoint': f'{self.base}/authorize', 'token_endpoint': f'{self.base}/token',
            'registration_endpoint': f'{self.base}/register', 'code_challenge_methods_supported': ['S256'],
            'grant_types_supported': ['authorization_code'], 'response_types_supported': ['code']})

    async def _register(self, request: Request):
        uris = (await request.json()).get('redirect_uris', [])
        self.registrations.append(uris)
        if not uris or not all(u.startswith('http://127.0.0.1') for u in uris):
            return JSONResponse({'error': 'invalid_redirect_uri'}, status_code=400)
        return JSONResponse({'client_id': 'client-loopback', 'redirect_uris': uris}, status_code=201)

    async def _token(self, request: Request):
        form = parse_qs((await request.body()).decode())
        grant = form.get('grant_type', [''])[0]
        self.grants.append(grant)
        if grant != 'authorization_code':
            return JSONResponse({'error': 'unsupported_grant_type'}, status_code=400)
        token = f'at-vendor-{len(self.grants)}'
        self.valid.add(token)
        return JSONResponse({'access_token': token, 'token_type': 'Bearer', 'expires_in': 3600})

    def __enter__(self):
        self._thread.start()
        wait_until(lambda: self._server.started, what='fake vendor started')
        return self

    def __exit__(self, *exc):
        self._server.should_exit = True
        self._thread.join(timeout=10)


@pytest.fixture
def vendor(tmp_path, monkeypatch):
    with FakeVendor() as fake:
        root = tmp_path / 'optional-mcps' / 'circleci'
        root.mkdir(parents=True)
        (root / 'manifest.yaml').write_text(
            f'manifest_version: 1\nname: circleci\ndescription: CircleCI test vendor.\nsource: https://circleci.com/docs\n'
            f'transport:\n  type: http\n  url: {fake.mcp_url}\nauth:\n  type: oauth\n')
        monkeypatch.setattr(mcp_catalog, '_catalog_root', lambda: tmp_path / 'optional-mcps')
        monkeypatch.setattr('hermes_cli.pal_connectors.device_sign_in_urls', lambda: {'circleci': fake.mcp_url})
        monkeypatch.setattr(mcp_oauth_import, '_https_url', lambda value: isinstance(value, str) and value.startswith(('https://', 'http://127.0.0.1')))
        yield fake


@pytest.mark.asyncio
async def test_against_a_loopback_only_vendor_the_device_signs_in_and_the_gateway_lists_tools_then_needs_sign_in(authorities, vendor):
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    authority = await authorities('home')
    phone = await connect_phone(authority)
    home = home_of(authority)

    assert vendor.registrations == []
    refused = await call_rpc(home, 'mcp.servers.add', {'name': 'circleci', 'preset': 'circleci'})
    assert refused['result']['ok'] is True
    start = await call_rpc(home, 'mcp.servers.oauth.start', {
        'name': 'circleci', 'client_redirect_uri': APP_REDIRECT, 'fallback_redirect_uri': LOOPBACK})
    assert start['error']['data'] == {'reason': 'SIGNIN_ON_DEVICE'}
    assert vendor.registrations == [], 'the gateway must not register an app or gateway redirect at the vendor'

    from tools.mcp_tool import sdk_httpx
    httpx = sdk_httpx()
    async with httpx.AsyncClient() as device:
        refused_app = await device.post(f'{vendor.base}/register', json={'redirect_uris': [APP_REDIRECT]})
        accepted = await device.post(f'{vendor.base}/register', json={'redirect_uris': [LOOPBACK]})
        issued = await device.post(f'{vendor.base}/token', content='grant_type=authorization_code&code=c',
                                   headers={'content-type': 'application/x-www-form-urlencoded'})
    assert (refused_app.status_code, accepted.status_code) == (400, 201) and len(vendor.registrations) == 2
    access = issued.json()['access_token']
    vendor.grants.clear()
    vendor.registrations.clear()

    submit = handover('circleci', access=access, refresh=None, token_endpoint=f'{vendor.base}/token', issuer=vendor.base)
    assert (await phone.call('auth.submit_oauth_tokens', submit))['result'] == {'ok': True}

    def probe():
        try:
            return rpc._methods['mcp.servers.test'](1, {'name': 'circleci', 'account': 'default'})
        finally:
            shutdown_mcp_servers()
    tested = (await _in_home(home, probe))['result']
    assert tested['ok'] is True and [t['name'] for t in tested['tools']] == ['list_pipelines']

    expire_access_token(home, 'circleci@default')
    vendor.valid.clear()
    catalog = row(await call_rpc(home, 'connectors.catalog'), 'circleci')
    assert catalog['status'] == 'needs_reconnect' and catalog['accounts'][0]['status'] == 'needs_reconnect'
    again = (await _in_home(home, probe))['result']
    assert again['ok'] is False
    assert vendor.grants == [] and vendor.registrations == [], 'no refresh and no new registration after the grant lapsed'
