import asyncio
import json
import threading
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

from tests.gateway.fixtures.local_recovery_probe import child_env, daemon, websocket
from tests.gateway.test_iphone_device_tools_e2e import IphoneModel, Phone, tool_messages, tools_of

ROOT = Path(__file__).resolve().parents[2]
DEVICE_ID = 'bot-chat-iphone-' + uuid.uuid4().hex[:8]


def tool_names(request):
    return [tool['function']['name'] for tool in request.get('tools') or []]


def test_a_bot_chat_started_on_the_desktop_carries_the_iphone_tool_once_a_phone_is_registered(tmp_path):
    home, user = tmp_path / 'state', tmp_path / 'user'
    home.mkdir(mode=0o700)
    user.mkdir()
    model = ThreadingHTTPServer(('127.0.0.1', 0), IphoneModel)
    model.requests = []
    thread = threading.Thread(target=model.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{model.server_port}/v1'
    (home / 'config.yaml').write_text(json.dumps({
        'gateway': {'multiplex_profiles': False},
        'model': {'provider': 'custom', 'default': 'stub', 'base_url': base},
        'auxiliary': {'title_generation': {'enabled': False}},
        'terminal': {'cwd': str(home)},
        'iphone': {'timeout_seconds': 20},
    }))
    env = child_env() | dict(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(ROOT),
                             OPENAI_API_KEY='loopback-only', OPENAI_BASE_URL=base, PYTHONUNBUFFERED='1')
    seen = {}

    async def register_phone(desc):
        async with websocket(home, desc) as ws:
            phone = Phone(ws)
            await phone.call('client.hello', kind='ios', device_id=DEVICE_ID, label='E2E iPhone', app_version='1.0',
                             accepts_offers=False, device_tools=True, attention='foreground')
            await phone.call('device_connectors.set', id='contacts', state='allowed')
            await phone.close()

    async def drive(desc):
        async with websocket(home, desc) as ws:
            desk = Phone(ws, answers=False)
            plain = await desk.call('session.create', request_id=uuid.uuid4().hex, source='gui', cwd=str(home))
            await desk.turn(plain['session_id'], 'CONTACTS_PLEASE')
            seen['plain_requests'] = len(model.requests)
            chat = await desk.call('session.create', request_id=uuid.uuid4().hex, source='gui', cwd=str(home),
                                   title='Bot Chat', hidden=True)
            await desk.turn(chat['session_id'], 'CONTACTS_PLEASE')
            seen['offline_phone_requests'] = len(model.requests)
            async with websocket(home, desc) as phone_ws:
                phone = Phone(phone_ws)
                await phone.call('client.hello', kind='ios', device_id=DEVICE_ID, label='E2E iPhone',
                                 app_version='1.0', accepts_offers=False, device_tools=True, attention='foreground')
                await desk.turn(chat['session_id'], 'CONTACTS_PLEASE')
                seen['phone_asked'] = [request['action'] for request in phone.requests]
                await phone.close()
            await desk.turn(chat['session_id'], 'CONTACTS_PLEASE')
            await desk.close()

    try:
        with daemon(ROOT, home, env, barrier=False) as (_proc, desc):
            asyncio.run(register_phone(desc))
            asyncio.run(drive(desc))
    finally:
        model.shutdown()
        model.server_close()
        thread.join(timeout=5)

    requests = [request for request in model.requests if request.get('tools') or request.get('messages')]
    plain_turn = requests[:seen['plain_requests']]
    chat_turns = requests[seen['plain_requests']:]
    assert plain_turn and all('iphone' not in tool_names(request) for request in plain_turn)
    assert chat_turns and all('iphone' in tool_names(request) for request in chat_turns if request.get('tools'))
    assert len({tools_of(request) for request in chat_turns if request.get('tools')}) == 1, (
        'the tool list never changed across the phone disconnecting, connecting and disconnecting')
    assert seen['phone_asked'] == ['contacts.search']
    results = [message for request in chat_turns for message in tool_messages(request)]
    assert any('phone_offline' in message for message in results)
    assert any('Sam Rivera' in message for message in results)
