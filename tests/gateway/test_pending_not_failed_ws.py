import asyncio
import json
import os
import stat
from pathlib import Path

import pytest
from tests.waiting import async_wait_until
import pytest_asyncio

from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall

CANARY = 'CANARY-NOT-A-SECRET'
STUB_OK = 'stub-inbox-ok'
HIMALAYA = ['himalaya', 'envelope', 'list', '--output', 'json']


def _install_himalaya_stub(bin_dir: Path, env_file: Path) -> None:
    bin_dir.mkdir()
    script = bin_dir / 'himalaya'
    script.write_text(
        '#!/bin/sh\n'
        f'if grep -q "^HIMALAYA_PASSWORD=." "{env_file}" 2>/dev/null; then\n'
        f'  echo \'[{{"id":"1","subject":"{STUB_OK}"}}]\'\n'
        '  exit 0\n'
        'fi\n'
        'echo \'{"error":"Secret command error: ","sources":[]}\'\n'
        'exit 1\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    failing = bin_dir / 'fail-with-three'
    failing.write_text('#!/bin/sh\necho real-failure-output\nexit 3\n')
    failing.chmod(failing.stat().st_mode | stat.S_IXUSR)


class Session:
    def __init__(self, ws):
        self.ws = ws
        self.frames: list[dict] = []
        self.replies: dict = {}
        self._ids = 0
        self._reader = asyncio.create_task(self._read())

    async def _read(self):
        async for raw in self.ws:
            frame = json.loads(raw)
            if 'id' in frame and ('result' in frame or 'error' in frame):
                self.replies[frame['id']] = frame
            else:
                self.frames.append(frame)

    async def rpc(self, method, **params):
        self._ids += 1
        rid = self._ids
        await self.ws.send(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
        await async_wait_until(lambda: rid in self.replies, timeout=15, what=f'reply {rid}')
        return self.replies[rid]

    def events(self, kind):
        return [f['params'] for f in self.frames if f.get('params', {}).get('type') == kind]

    async def wait_for(self, predicate, timeout=30):
        return await async_wait_until(predicate, timeout=timeout, what='frame')


@pytest_asyncio.fixture
async def gateway(tmp_path, monkeypatch):
    from gateway.config import GatewayConfig
    from gateway.control_socket import GatewayControlServer
    from gateway.run import GatewayRunner
    from gateway.run_runtime import initialize_gateway_runtime, publish_gateway_runtime_ready, start_gateway_runtime_api
    from gateway.runtime_ownership import process_ownership
    from hermes_cli import web_server as web
    from hermes_constants import get_hermes_home

    home = get_hermes_home()
    _install_himalaya_stub(tmp_path / 'bin', home / '.env')
    monkeypatch.setenv('PATH', f'{tmp_path / "bin"}{os.pathsep}{os.environ["PATH"]}')
    holder = {}

    async def start(script):
        server = FakeLLMServer(script)
        server.start()
        holder['llm'] = server
        (home / 'config.yaml').write_text(json.dumps({
            'model': {'provider': 'custom', 'default': 'fake-model', 'base_url': server.base_url, 'api_key': 'sk-fake-e2e'},
            'platform_toolsets': {'cli': ['terminal']}, 'auxiliary': {'title_generation': {'enabled': False}}}))
        import gateway.run as gateway_run
        monkeypatch.setattr(gateway_run, '_hermes_home', home)
        monkeypatch.setattr(gateway_run, '_resolve_runtime_agent_kwargs', lambda: {
            'api_key': 'sk-fake-e2e', 'base_url': server.base_url, 'provider': 'custom', 'api_mode': 'chat_completions'})
        process_ownership.reserve([home])
        runner = GatewayRunner(GatewayConfig())
        holder['runner'] = runner
        await initialize_gateway_runtime(runner)
        runner.session_control_server = GatewayControlServer()
        assert await runner.session_control_server.start()
        await start_gateway_runtime_api(runner)
        assert await runner.start()
        publish_gateway_runtime_ready(runner)
        url = runner.session_api.api_origin.replace('http:', 'ws:') + '/api/ws?token=' + web._SESSION_TOKEN
        from websockets.asyncio.client import connect
        ws = await connect(url)
        holder['ws'] = ws
        session = Session(ws)
        holder['session'] = session
        hello = await session.rpc('client.hello', kind='ios', label='iPhone', app_version='1.0', accepts_offers=True,
                                  device_id='device-pending-ws0', device_tools=False, attention='foreground')
        assert hello['result']['recorded'] is True, hello
        created = await session.rpc('session.create', request_id='pending-ws', source='cli')
        assert 'result' in created, created
        return session, created['result']['session_id'], server

    yield start
    from gateway import auth_prompts
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()
    if 'session' in holder:
        holder['session']._reader.cancel()
        await holder['ws'].close()
    if 'runner' in holder:
        await holder['runner'].stop()
        await holder['runner'].session_control_server.stop()
        process_ownership.close()
    if 'llm' in holder:
        holder['llm'].stop()


FAILURE_MARKERS = ('Secret command error', 'auth_declined', 'auth_timeout', 'auth_failed')


def _dump(session):
    return json.dumps(session.frames, default=str)


async def _turn_until_prompt(gateway, command, script_text='final answer'):
    session, sid, llm = await gateway([ToolCall('terminal', {'command': command}), Text(script_text)])
    submitted = await session.rpc('prompt.submit', session_id=sid, input_id='i1', text='check my mail')
    assert submitted['result']['status'] == 'queued', submitted
    return session, sid, llm


async def _prompt(session):
    frames = await session.wait_for(lambda: [f for f in session.frames
                                             if f.get('params', {}).get('type') == 'auth.required'])
    return frames[0]['params']['payload']


async def _settled(session, llm):
    await session.wait_for(lambda: session.events('tool.complete'))
    await session.wait_for(lambda: len(llm.main_requests()) >= 2)
    return session.events('tool.complete')[0], _fed_back_result(llm)


def _fed_back_result(llm):
    tool_messages = [m for m in llm.main_requests()[1]['messages'] if m['role'] == 'tool']
    assert len(tool_messages) == 1
    return json.loads(tool_messages[0]['content'])


def _proof(capsys, label, **fields):
    with capsys.disabled():
        print(f'\nPROOF {label} ' + ' '.join(f'{k}={v!r}' for k, v in fields.items()))


@pytest.mark.asyncio
async def test_unanswered_prompt_holds_the_outcome_open(gateway, capsys):
    session, _sid, llm = await _turn_until_prompt(gateway, ' '.join(HIMALAYA))
    prompt = await _prompt(session)
    assert prompt['service'] == 'email:himalaya' and prompt['flow'] == 'api_key'
    await asyncio.sleep(3)  # health: allow HX013 -- proving nothing completes while the prompt is open
    started = [e for e in session.events('tool.start') if e['payload']['name'] == 'terminal']
    assert len(started) == 1
    assert session.events('tool.complete') == []
    assert len(llm.main_requests()) == 1
    dump = _dump(session)
    leaked = [m for m in FAILURE_MARKERS if m in dump]
    _proof(capsys, 'pending', auth_required=prompt['request_id'][:8], tool_complete_frames=0,
           model_requests_so_far=len(llm.main_requests()), failure_markers_seen=leaked)
    assert leaked == []
    await session.rpc('auth.decline', request_id=prompt['request_id'])
    await _settled(session, llm)


@pytest.mark.asyncio
async def test_answered_prompt_retries_and_reports_the_real_output(gateway, capsys, caplog, monkeypatch):
    import logging
    from hermes_constants import get_hermes_home
    caplog.set_level(logging.DEBUG)
    session, _sid, llm = await _turn_until_prompt(gateway, ' '.join(HIMALAYA))
    prompt = await _prompt(session)
    assert session.events('tool.complete') == []
    reply = await session.rpc('auth.submit_credential', request_id=prompt['request_id'], value=CANARY)
    assert reply['result']['outcome'] == 'stored', reply
    _complete, fed_back = await _settled(session, llm)
    _proof(capsys, 'answered', outcome=reply['result']['outcome'], exit_code=fed_back.get('exit_code'),
           output=fed_back.get('output'), has_error_type='error_type' in fed_back)
    assert fed_back.get('exit_code') == 0 and STUB_OK in fed_back['output']
    assert 'error_type' not in fed_back and 'pending' not in fed_back
    assert not any(m in json.dumps(fed_back) for m in FAILURE_MARKERS)
    assert f'HIMALAYA_PASSWORD={CANARY}' in (get_hermes_home() / '.env').read_text()
    outside_store = '\n'.join([_dump(session), json.dumps(llm.requests, default=str), caplog.text])
    assert CANARY not in outside_store


@pytest.mark.asyncio
async def test_declined_prompt_reports_auth_declined(gateway, capsys):
    session, _sid, llm = await _turn_until_prompt(gateway, ' '.join(HIMALAYA))
    prompt = await _prompt(session)
    declined = await session.rpc('auth.decline', request_id=prompt['request_id'])
    assert declined['result']['recorded'] is True
    _complete, fed_back = await _settled(session, llm)
    _proof(capsys, 'declined', error_type=fed_back.get('error_type'))
    assert fed_back['error_type'] == 'auth_declined'
    assert 'pending' not in fed_back


@pytest.mark.asyncio
async def test_unanswered_prompt_times_out_as_auth_timeout(gateway, capsys, monkeypatch):
    from gateway import auth_prompts
    monkeypatch.setattr(auth_prompts, 'SIGNIN_TIMEOUT_SECONDS', 1.0)
    monkeypatch.setattr(auth_prompts, 'MAX_SIGNIN_SECONDS', 2.0)
    session, _sid, llm = await _turn_until_prompt(gateway, ' '.join(HIMALAYA))
    await _prompt(session)
    _complete, fed_back = await _settled(session, llm)
    _proof(capsys, 'timeout', error_type=fed_back.get('error_type'))
    assert fed_back['error_type'] == 'auth_timeout'
    assert 'pending' not in fed_back


@pytest.mark.asyncio
async def test_real_failure_without_a_prompt_is_reported_as_failed(gateway, capsys):
    session, _sid, llm = await _turn_until_prompt(gateway, 'fail-with-three')
    _complete, fed_back = await _settled(session, llm)
    _proof(capsys, 'negative-control', exit_code=fed_back.get('exit_code'), keys=sorted(fed_back))
    assert fed_back['exit_code'] == 3 and 'real-failure-output' in fed_back['output']
    assert 'pending' not in fed_back
    assert session.events('auth.required') == []
