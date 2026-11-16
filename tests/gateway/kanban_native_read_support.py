"""Real-daemon harness shared by the Kanban native-read suite and its isolated probe.

Starts the ordinary ``gateway.run`` process on a disposable ``HERMES_HOME``, mints a ticket over its
private control channel and speaks to ``/api/ws`` exactly as the native Pal client does (the
``hermes-gateway-v1`` plus ticket subprotocols). No model is configured or launched, no platform
adapter runs, and the Kanban root is a disposable directory.
"""
import asyncio
import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from websockets.asyncio.client import connect

from tests.gateway.test_normal_runtime_boot import control

ROOT = Path(__file__).resolve().parents[2]


def isolated_env(home: Path, user: Path, kanban_home: Path) -> dict:
    env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TZ', 'TIRITH_ENABLED') if k in os.environ}
    env.update(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), HERMES_KANBAN_HOME=str(kanban_home),
               PYTHONPATH=str(ROOT), PYTHONUNBUFFERED='1')
    return env


def write_gateway_config(home: Path) -> None:
    (home / 'config.yaml').write_text(json.dumps({
        'gateway': {'multiplex_profiles': False},
        'model': {'provider': 'custom', 'default': 'kanban-read-fixture', 'base_url': 'http://127.0.0.1:1/v1'},
        'auxiliary': {'title_generation': {'enabled': False}},
    }))


@contextlib.contextmanager
def running_gateway(home: Path, env: dict):
    log_path = home.parent / 'gateway.log'
    with log_path.open('w+') as log:
        process = subprocess.Popen([sys.executable, '-m', 'gateway.run'], cwd=ROOT, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            descriptor, deadline = {}, time.monotonic() + 60
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    descriptor = control(home, 'identify')
                    if descriptor.get('state') == 'ready':
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(.1)
            log.seek(0)
            assert descriptor.get('state') == 'ready', (descriptor, log.read())
            yield descriptor
            process.send_signal(signal.SIGINT)
            process.wait(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


def ticket(home: Path, descriptor: dict, purpose: str = 'interactive') -> str:
    return control(home, 'session-ticket', {'profile_id': str(home.resolve()), 'instance_id': descriptor['instance_id'],
                                            'purpose': purpose})['ticket']


class NativeSocket:

    def __init__(self, ws):
        self.ws, self.n = ws, 0

    async def call(self, method, **params):
        self.n += 1
        rid = f'{method}#{self.n}'
        await self.ws.send(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
        async with asyncio.timeout(20):
            while True:
                reply = json.loads(await self.ws.recv())
                if reply.get('id') == rid:
                    return reply

    async def result(self, method, **params):
        reply = await self.call(method, **params)
        assert 'result' in reply, reply
        return reply['result']


@contextlib.asynccontextmanager
async def native_socket(home: Path, descriptor: dict, purpose: str = 'interactive'):
    url = descriptor['api_origin'].replace('http:', 'ws:') + '/api/ws'
    async with connect(url, subprotocols=['hermes-gateway-v1', 'hermes-gateway-ticket.' + ticket(home, descriptor, purpose)]) as ws:
        yield NativeSocket(ws)
