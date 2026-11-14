import asyncio
import json
import types
from pathlib import Path

import hermes_yaml as yaml
import pytest

from tests.gateway.device_tools_harness import call_tool, connect_phone, home_of
from tests.waiting import async_wait_until

from tools.mcp_tool_schema import mcp_prefixed_tool_name

ECHO_NAME = mcp_prefixed_tool_name('t3code', 'echo')
ECHO_TOOL = {'name': 'echo', 'description': 'Echo the text back',
             'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}}


def _reply(request, result):
    return {'jsonrpc': '2.0', 'id': request['id'], 'result': result}


def echo_server(message):
    method, params = message.get('method'), message.get('params') or {}
    if method == 'initialize':
        return [_reply(message, {'protocolVersion': params['protocolVersion'], 'capabilities': {'tools': {}},
                                 'serverInfo': {'name': 'fake-t3', 'version': '1.0'}})]
    if method == 'tools/list':
        return [_reply(message, {'tools': [ECHO_TOOL]})]
    if method == 'tools/call':
        text = (params.get('arguments') or {}).get('text', '')
        return [_reply(message, {'content': [{'type': 'text', 'text': f'echo:{text}'}]})]
    if method == 'ping':
        return [_reply(message, {})]
    return []


class Mac:
    def __init__(self, phone, behaviour):
        self.phone = phone
        self.behaviour = behaviour
        self.served = []
        self.closed = []
        self.muted = False
        phone.write = types.MethodType(self._write, phone)

    def _write(self, phone, frame):
        accepted = type(phone).write(phone, frame)
        kind, payload = frame['params']['type'], frame['params']['payload']
        if accepted and kind == 'device.mcp.frame':
            self.served.append(payload)
            if not self.muted:
                asyncio.run_coroutine_threadsafe(self._serve(payload), phone.loop)
        if accepted and kind == 'device.mcp.close':
            self.closed.append(payload)
        return accepted

    async def _serve(self, payload):
        for reply in self.behaviour(payload['message']):
            await self.deliver(payload['relay_id'], reply)

    async def deliver(self, relay_id, message):
        return await self.phone.call('device.mcp.deliver', {'relay_id': relay_id, 'message': message})

    async def fail(self, relay_id, code, message=''):
        return await self.phone.call('device.mcp.fail', {'relay_id': relay_id, 'code': code, 'message': message})

    async def register(self, server='t3code'):
        return await self.phone.call('device.mcp.register', {'server': server})

    async def unregister(self, server='t3code'):
        return await self.phone.call('device.mcp.unregister', {'server': server})

    def relays(self):
        return list(dict.fromkeys(payload['relay_id'] for payload in self.served))

    def methods(self):
        return [payload['message'].get('method') for payload in self.served]


async def connect_mac(authority, label='Mac', behaviour=echo_server) -> Mac:
    return Mac(await connect_phone(authority, label, kind='mac'), behaviour)


def servers_in_config(authority) -> dict:
    path = home_of(authority) / 'config.yaml'
    return (yaml.safe_load(path.read_text()) or {}).get('mcp_servers', {}) if path.exists() else {}


def mcp_tool_names(authority) -> list:
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from tools.registry import registry
    token = set_hermes_home_override(home_of(authority))
    try:
        return sorted(name for name in registry.get_all_tool_names() if name.startswith('mcp__t3code__'))
    finally:
        reset_hermes_home_override(token)


async def registered(mac, authority) -> dict:
    from gateway import device_mcp_registration
    reply = await mac.register()
    assert reply['result'] == {'registered': True, 'name': 't3code'}, reply
    await device_mcp_registration.settled()
    return reply['result']


async def wait_for_tools(authority, what='t3code tools registered'):
    await async_wait_until(lambda: mcp_tool_names(authority) == [ECHO_NAME], what=what, timeout=30)


async def call_echo(authority, text='hello') -> dict:
    return await call_tool(authority, ECHO_NAME, {'text': text})


@pytest.fixture(autouse=True)
def clean_device_mcp():
    yield
    from gateway import device_mcp_registration, device_mcp_relay
    from tools import mcp_tool_device
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    shutdown_mcp_servers()
    device_mcp_relay._relays.clear()
    device_mcp_registration._background.clear()
    mcp_tool_device._auth.clear()
