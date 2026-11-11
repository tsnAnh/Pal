import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_constants import reset_hermes_home_override, set_hermes_home_override

HELLO = {'kind': 'ios', 'label': 'iPhone', 'app_version': '1.0', 'accepts_offers': True, 'device_tools': True}


class FakePhone:
    def __init__(self, loop, responder=None):
        self.loop = loop
        self.responder = responder
        self.frames: list[dict] = []
        self.connection = None
        self.desktop_local = False
        self.accept_writes = True
        self._ids = 0

    def events(self, type_: str) -> list[dict]:
        return [f['params']['payload'] for f in self.frames if f['params']['type'] == type_]

    def requests(self) -> list[dict]:
        return self.events('device.tool.request')

    def write(self, frame: dict) -> bool:
        self.frames.append(frame)
        if not self.accept_writes:
            return False
        if frame['params']['type'] == 'device.tool.request' and self.responder is not None:
            payload = frame['params']['payload']
            answer = self.responder(payload)
            if answer is not None:
                asyncio.run_coroutine_threadsafe(self.respond(payload['request_id'], answer), self.loop)
        return True

    async def call(self, method: str, params: dict) -> dict:
        self._ids += 1
        return await self.connection.dispatch({'id': self._ids, 'method': method, 'params': params})

    async def respond(self, request_id: str, answer: dict) -> dict:
        return await self.call('device.tool.respond', {'request_id': request_id, **answer})


async def make_authority(home: Path):
    from gateway.session_authority import SessionAuthority
    from gateway.session_cron import bind_owner
    from hermes_state import SessionDB
    from hermes_state_runtime import begin_runtime_epoch
    home.mkdir(parents=True, exist_ok=True)
    db = SessionDB(db_path=home / 'state.db')
    authority = SessionAuthority(SimpleNamespace(_draining=False), profile_id=str(home), instance_id='owner', db=db,
                                 epoch=begin_runtime_epoch(db, instance_id='owner'))
    bind_owner(authority)
    return authority


def release_authority(authority) -> None:
    from gateway.session_cron import unbind_owner
    unbind_owner(authority)
    authority.db.close()


@pytest.fixture
def authorities(tmp_path):
    built = []

    async def build(name='home'):
        authority = await make_authority(tmp_path / name)
        built.append(authority)
        return authority

    yield build
    for authority in built:
        release_authority(authority)


def device_id_for(label: str) -> str:
    return f'device-{label}'.ljust(12, '0')


async def connect_phone(authority, label: str = 'iPhone', *, responder=None, device_tools: bool = True,
                        attention: str = 'foreground', kind: str = 'ios') -> FakePhone:
    from gateway.session_controls import AuthorityConnection
    phone = FakePhone(asyncio.get_running_loop(), responder)
    phone.connection = AuthorityConnection(authority, phone, {'user_id': 'owner'})
    reply = await phone.call('client.hello', {**HELLO, 'kind': kind, 'label': label, 'device_id': device_id_for(label),
                                              'device_tools': device_tools, 'attention': attention})
    assert reply['result']['recorded'] is True, reply
    return phone


async def set_state(phone: FakePhone, connector: str, state: str) -> dict:
    reply = await phone.call('device_connectors.set', {'id': connector, 'state': state})
    assert 'result' in reply, reply
    return reply['result']


def home_of(authority) -> Path:
    return Path(authority.db.db_path).resolve().parent


async def call_iphone(authority, action: str, args: dict | None = None, *, session_id: str = 'chat-1') -> dict:
    from model_tools import handle_function_call
    home = home_of(authority)

    def run() -> str:
        token = set_hermes_home_override(home)
        try:
            payload = {'action': action} if args is None else {'action': action, 'args': args}
            return handle_function_call('iphone', payload, task_id='t', session_id=session_id)
        finally:
            reset_hermes_home_override(token)

    return json.loads(await asyncio.to_thread(run))


def contacts_answer(payload: dict) -> dict:
    return {'ok': True, 'result': {'contacts': [{
        'id': 'c1', 'name': 'Sam\U000e0001\U000e0049 Rivera', 'organization': 'Acme',
        'phones': ['+1 555 0100'], 'emails': ['sam@example.com'], 'unexpected': 'dropped'}]}}


class Approvals:
    def __init__(self, monkeypatch, choice: str):
        from tools import approval, approval_context, approval_prompt
        self.prompts: list[tuple] = []
        monkeypatch.setattr(approval, '_is_interactive_cli', lambda: True)
        monkeypatch.setattr(approval, '_is_gateway_approval_context', lambda: False)
        monkeypatch.setattr(approval_context, '_is_gateway_approval_context', lambda: False)

        def answer(*args, **kwargs):
            self.prompts.append(args)
            return self.choice

        self.choice = choice
        monkeypatch.setattr(approval, 'prompt_dangerous_approval', answer)
        monkeypatch.setattr(approval_prompt, 'prompt_dangerous_approval', answer)
