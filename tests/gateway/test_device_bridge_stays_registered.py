import asyncio
import json

import pytest
import pytest_asyncio

from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall
from tests.waiting import async_wait_until

DEVICE_TOOLS = {'device', 'devices_list'}
MAC = 'mac-bridge-0001'


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.frames = []
        self.replies = {}
        self._ids = 0
        self._reader = asyncio.create_task(self._read())

    async def _read(self):
        try:
            async for raw in self.ws:
                frame = json.loads(raw)
                if 'id' in frame and ('result' in frame or 'error' in frame):
                    self.replies[frame['id']] = frame
                else:
                    self.frames.append(frame)
        except Exception:
            pass

    async def rpc(self, method, **params):
        self._ids += 1
        rid = self._ids
        await self.ws.send(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
        await async_wait_until(lambda: rid in self.replies, timeout=15, what=f'reply {rid}')
        return self.replies[rid]

    async def hello(self, device_tools=True):
        reply = await self.rpc('client.hello', kind='mac', label='Work Mac', app_version='1.0', accepts_offers=False,
                               device_id=MAC, device_tools=device_tools, attention='foreground')
        assert reply['result']['recorded'] is True, reply
        return reply

    async def close(self):
        self._reader.cancel()
        await self.ws.close()


class Bridge:
    def __init__(self, tmp_path, monkeypatch):
        self.tmp_path, self.monkeypatch = tmp_path, monkeypatch
        self.llm = None
        self.runner = None
        self.clients = []

    async def start(self):
        from gateway.config import GatewayConfig
        from gateway.control_socket import GatewayControlServer
        from gateway.run import GatewayRunner
        from gateway.run_runtime import (
            initialize_gateway_runtime, publish_gateway_runtime_ready, start_gateway_runtime_api)
        from gateway.runtime_ownership import process_ownership
        from hermes_constants import get_hermes_home
        home = get_hermes_home()
        if self.llm is None:
            self.llm = FakeLLMServer([])
            self.llm.start()
        (home / 'config.yaml').write_text(json.dumps({
            'model': {'provider': 'custom', 'default': 'fake-model', 'base_url': self.llm.base_url,
                      'api_key': 'sk-fake-e2e'},
            'platform_toolsets': {'cli': ['file']}, 'auxiliary': {'title_generation': {'enabled': False}}}))
        import gateway.run as gateway_run
        self.monkeypatch.setattr(gateway_run, '_hermes_home', home)
        self.monkeypatch.setattr(gateway_run, '_resolve_runtime_agent_kwargs', lambda: {
            'api_key': 'sk-fake-e2e', 'base_url': self.llm.base_url, 'provider': 'custom',
            'api_mode': 'chat_completions'})
        process_ownership.reserve([home])
        self.runner = GatewayRunner(GatewayConfig())
        await initialize_gateway_runtime(self.runner)
        self.runner.session_control_server = GatewayControlServer()
        assert await self.runner.session_control_server.start()
        await start_gateway_runtime_api(self.runner)
        assert await self.runner.start()
        publish_gateway_runtime_ready(self.runner)

    async def stop(self):
        from gateway.runtime_ownership import process_ownership
        for client in self.clients:
            await client.close()
        self.clients.clear()
        await self.runner.stop()
        await self.runner.session_control_server.stop()
        process_ownership.close()

    async def restart(self):
        await self.stop()
        await self.start()

    async def dial(self):
        from hermes_cli import web_server as web
        from websockets.asyncio.client import connect
        url = self.runner.session_api.api_origin.replace('http:', 'ws:') + '/api/ws?token=' + web._SESSION_TOKEN
        client = Client(await connect(url))
        self.clients.append(client)
        return client

    async def turn(self, client, session_id, script):
        before = len(self.llm.main_requests())
        self.llm.push(*script)
        reply = await client.rpc('prompt.submit', session_id=session_id, input_id=f'i{before}', text='go')
        assert reply['result']['status'] == 'queued', reply
        await async_wait_until(lambda: len(self.llm.main_requests()) >= before + len(script), timeout=30, what='turn')
        return self.llm.main_requests()[before:]


@pytest_asyncio.fixture
async def bridge(tmp_path, monkeypatch):
    holder = Bridge(tmp_path, monkeypatch)
    await holder.start()
    yield holder
    from gateway import auth_prompts
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()
    await holder.stop()
    holder.llm.stop()


def names(request):
    return {tool['function']['name'] for tool in request.get('tools') or []}


async def chats(bridge, owner):
    plain = await owner.rpc('session.create', request_id='plain', source='gui')
    bot = await owner.rpc('session.create', request_id='bot', source='gui', title='Bot Chat', hidden=True)
    return {'chat': plain['result']['session_id'], 'bot_chat': bot['result']['session_id']}


def listed_status(requests):
    tool = next(m for m in reversed(requests[-1]['messages']) if m['role'] == 'tool')
    (device,) = json.loads(tool['content'])['devices']
    return device['status']


@pytest.mark.asyncio
async def test_tools_survive_disconnect_and_reconnect(bridge):
    phone = await bridge.dial()
    await phone.hello()
    owner = await bridge.dial()
    sessions = await chats(bridge, owner)
    for kind, sid in sessions.items():
        (request,) = await bridge.turn(owner, sid, [Text('ok')])
        assert DEVICE_TOOLS <= names(request), (kind, sorted(names(request)))
    await phone.close()
    for kind, sid in sessions.items():
        requests = await bridge.turn(owner, sid, [ToolCall('devices_list', {}), Text('ok')])
        assert DEVICE_TOOLS <= names(requests[0]), ('after close', kind, sorted(names(requests[0])))
        assert listed_status(requests) == 'offline', kind
    again = await bridge.dial()
    await again.hello()
    for kind, sid in sessions.items():
        requests = await bridge.turn(owner, sid, [ToolCall('devices_list', {}), Text('ok')])
        assert DEVICE_TOOLS <= names(requests[0]), ('after reconnect', kind, sorted(names(requests[0])))
        assert listed_status(requests) == 'online', kind


@pytest.mark.asyncio
async def test_tools_present_after_gateway_restart_and_first_hello(bridge):
    phone = await bridge.dial()
    await phone.hello()
    await bridge.restart()
    owner = await bridge.dial()
    sessions = await chats(bridge, owner)
    for kind, sid in sessions.items():
        (request,) = await bridge.turn(owner, sid, [Text('ok')])
        assert DEVICE_TOOLS <= names(request), ('persisted registration, no hello yet', kind, sorted(names(request)))


@pytest.mark.asyncio
async def test_a_store_that_cannot_be_read_does_not_unlist_the_tools(bridge):
    from gateway import device_connectors
    from hermes_constants import get_hermes_home
    phone = await bridge.dial()
    await phone.hello()
    owner = await bridge.dial()
    (request,) = await bridge.turn(owner, (await chats(bridge, owner))['chat'], [Text('ok')])
    assert DEVICE_TOOLS <= names(request)
    (get_hermes_home() / device_connectors.FILE_NAME).write_text('{')
    fresh = await owner.rpc('session.create', request_id='after-unreadable', source='gui')
    (request,) = await bridge.turn(owner, fresh['result']['session_id'], [Text('ok')])
    assert DEVICE_TOOLS <= names(request), sorted(names(request))
