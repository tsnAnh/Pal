import asyncio
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest
from websockets.asyncio.client import connect

import hermes_yaml as yaml
from tests.fakes.fake_llm_provider import MODEL_ID, FakeLLMServer, Text, ToolCall
from tests.gateway.fixtures.local_recovery_probe import child_env, daemon, rpc
from tests.gateway.test_normal_runtime_boot import control
from tests.waiting import async_wait_until

ROOT = Path(__file__).resolve().parents[2]
CHIEF = "chief"
NOTHING_MADE = "does not let this terminal's profile create profiles; nothing was created"


@contextmanager
def _bots(tmp_path: Path):
    home, user, shim = tmp_path / "state", tmp_path / "user", tmp_path / "bin" / "hermes"
    chief = home / "profiles" / CHIEF
    for made in (chief, user, shim.parent):
        made.mkdir(parents=True)
    home.chmod(0o700)
    shim.write_text(f'#!/bin/sh\nPYTHONPATH={ROOT} exec {sys.executable} -m hermes_cli.main "$@"\n', encoding="utf-8")
    shim.chmod(0o755)
    with FakeLLMServer() as llm:
        model = {"provider": "custom", "default": MODEL_ID, "base_url": llm.base_url, "api_key": "loopback-only"}
        shared = {"model": model, "auxiliary": {"title_generation": {"enabled": False}}, "approvals": {"mode": "off"}}
        (home / "config.yaml").write_text(json.dumps({**shared, "gateway": {"multiplex_profiles": True}}))
        (chief / "config.yaml").write_text(json.dumps({**shared, "bot_mode": {"background_after_seconds": 2}}))
        (chief / "profile.yaml").write_text(json.dumps({"ui_meta": {"hermes-bots": {"title": CHIEF}}}))
        env = child_env()
        env.update(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(ROOT),
                   PATH=f"{shim.parent}{os.pathsep}{env['PATH']}", PYTHONUNBUFFERED="1")
        with daemon(ROOT, home, env, barrier=False) as (_process, descriptor):
            yield home, descriptor, env, llm


def _app(home: Path, descriptor: dict):
    grant = control(home, "session-ticket", {"profile_id": str(home.resolve()), "scope": "host",
                                             "instance_id": descriptor["instance_id"], "purpose": "interactive"})
    return connect(descriptor["api_origin"].replace("http:", "ws:") + "/api/ws",
                   subprotocols=["hermes-gateway-v1", "hermes-gateway-ticket." + grant["ticket"]], max_size=None)


async def _open(ws, cwd: Path, **params) -> str:
    opened = await rpc(ws, "session.create", profile=CHIEF, request_id="owner", source="ios", cwd=str(cwd),
                       toolsets=["terminal", "code_execution"], **params)
    assert "result" in opened, opened
    return opened["result"]["session_id"]


async def _owner_turn(ws, llm: FakeLLMServer, session_id: str, input_id: str, tool: str, **args) -> str:
    seen = len(llm.requests)
    llm.push(ToolCall(tool, args), Text(f"done {input_id}"))
    sent = await rpc(ws, "prompt.submit", profile=CHIEF, session_id=session_id, input_id=input_id,
                     text="make me a bot")
    assert "result" in sent, sent

    def result():
        return next((str(request["body"]["messages"][-1]["content"]) for request in llm.requests[seen:]
                     if request["body"]["messages"][-1]["role"] == "tool"), None)

    async def drain():
        while True:
            await ws.recv()

    draining = asyncio.ensure_future(drain())
    try:
        await async_wait_until(result, timeout=150, interval=.1, what=f"the {tool} result")
    finally:
        draining.cancel()
        await asyncio.gather(draining, return_exceptions=True)
    return result()


def _cli(env: dict, home: Path, *argv: str, **extra: str):
    return subprocess.run([sys.executable, "-m", "hermes_cli.main", *argv], cwd=ROOT, capture_output=True,
                          text=True, timeout=200, check=False, env={**env, "HERMES_HOME": str(home), **extra})


def _read(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


@pytest.mark.platforms("linux", "macos")
def test_the_owners_typed_turn_on_a_named_bot_creates_a_bot_through_the_running_gateway(tmp_path):
    with _bots(tmp_path) as (home, descriptor, env, llm):
        chief, kept = home / "profiles" / CHIEF, tmp_path / "kept-grant"

        async def drive():
            async with _app(home, descriptor) as ws:
                session_id = await _open(ws, tmp_path)
                shell = await _owner_turn(
                    ws, llm, session_id, "shell", "terminal",
                    command="hermes profile create scout; hermes profile create second")
                await _owner_turn(
                    ws, llm, session_id, "keep", "terminal",
                    command=f'printf %s "$HERMES_SESSION_CREATE_GRANT" > {kept}; false && hermes profile create no')
                form = await rpc(ws, "profiles.create", name="from-form", share_auth=True, clone_from="default",
                                 soul="# From Form", onboarding=True, display_name="From Form")
                return shell, form

        shell, form = asyncio.run(drive())

        assert "Profile 'scout' created at" in shell, shell
        made = home / "profiles" / "scout"
        assert _read(made / "config.yaml")["approvals"]["mode"] == "off"
        assert _read(made / "profile.yaml")["ui_meta"]["hermes-bots"]["title"] == "scout"
        assert NOTHING_MADE in shell, shell
        assert not (home / "profiles" / "second").exists()
        listed = _cli(env, home, "profile", "list")
        assert listed.returncode == 0 and "scout" in listed.stdout, listed.stdout + listed.stderr

        assert form["result"]["name"] == "from-form" and form["result"]["onboarding_pending"] is True, form
        assert (home / "profiles" / "from-form" / "SOUL.md").read_text(encoding="utf-8") == "# From Form"

        unused = kept.read_text(encoding="utf-8")
        assert unused
        for extra in ({}, {"HERMES_SESSION_CREATE_GRANT": "made-up-by-the-model"},
                      {"HERMES_SESSION_CREATE_GRANT": unused}):
            outside = _cli(env, chief, "profile", "create", "intruder", **extra)
            assert outside.returncode == 1 and NOTHING_MADE in outside.stdout, outside.stdout + outside.stderr
        assert not (home / "profiles" / "intruder").exists()


@pytest.mark.platforms("linux", "macos")
@pytest.mark.parametrize("session,tool,args,name,reported", [
    ({}, "terminal", {"command": "sleep 2; hermes profile create later", "background": True}, "later",
     "Background process started"),
    ({"title": "Bot Chat"}, "terminal", {"command": "sleep 8; hermes profile create slow"}, "slow",
     "yielded_to_background"),
    ({}, "execute_code", {"code": "import subprocess\n"
                                  "subprocess.run(['hermes', 'profile', 'create', 'scripted'], check=True)\n"},
     "scripted", "success"),
], ids=["background-command", "yielded-command", "script"])
def test_the_owners_typed_turn_creates_a_bot_outside_a_foreground_command(
        tmp_path, session, tool, args, name, reported):
    with _bots(tmp_path) as (home, descriptor, _env, llm):
        made = home / "profiles" / name

        async def drive():
            async with _app(home, descriptor) as ws:
                result = await _owner_turn(ws, llm, await _open(ws, tmp_path, **session), name, tool, **args)
                assert reported in result, result
                await async_wait_until(lambda: (made / "profile.yaml").is_file() and "hermes-bots" in
                                       (made / "profile.yaml").read_text(encoding="utf-8"),
                                       timeout=60, interval=.2, what=f"the bot from: {result}")

        asyncio.run(drive())

        assert _read(made / "config.yaml")["approvals"]["mode"] == "off"
