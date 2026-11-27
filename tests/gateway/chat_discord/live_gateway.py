from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

from websockets.asyncio.client import connect

from tests.gateway.chat_discord.fake_discord import GUILD_ID
from tests.gateway.chat_discord.live_discord import BOT_TOKEN, LiveDiscord
from tests.gateway.fixtures.shared_authority_peer import ModelPeer
from tests.gateway.test_multiplex_hot_serve_live import control
from tests.waiting import wait_until

ROOT = Path(__file__).resolve().parents[3]
REDIRECT = Path(__file__).parent / "live_redirect"
BOT = "chief"


class Multiplexer:
    def __init__(self, tmp_path: Path, discord: LiveDiscord):
        self.discord = discord
        self.home = tmp_path / "state"
        self.user = tmp_path / "user"
        self.stdout = tmp_path / "gateway.out"
        self.model = ThreadingHTTPServer(("127.0.0.1", 0), ModelPeer)
        self.model.requests, self.model.metadata_requests = [], []
        self.model_thread = threading.Thread(target=self.model.serve_forever, daemon=True)
        url = f"http://127.0.0.1:{self.model.server_port}/v1"
        config = {"gateway": {"multiplex_profiles": True},
                  "model": {"provider": "custom", "default": "local-wire-stub", "base_url": url},
                  "auxiliary": {"title_generation": {"enabled": False}}}
        self.user.mkdir()
        for home in (self.home, self.home / "profiles" / BOT):
            home.mkdir(parents=True, mode=0o700)
            (home / "config.yaml").write_text(json.dumps(config))
        env = {key: os.environ[key] for key in ("PATH", "LANG", "TZ") if key in os.environ}
        env.update(HOME=str(self.user), USERPROFILE=str(self.user), HERMES_HOME=str(self.home),
                   PYTHONPATH=os.pathsep.join((str(REDIRECT), str(ROOT))), PYTHONUNBUFFERED="1",
                   OPENAI_API_KEY="loopback-only", OPENAI_BASE_URL=url, PAL_TEST_FAKE_DISCORD=discord.url,
                   NO_PROXY="127.0.0.1,localhost")
        self.env = env
        self.process: subprocess.Popen | None = None
        self.backend: subprocess.Popen | None = None
        self.backend_url = ""
        self.replies: list[dict] = []
        self.identity: dict = {}

    def __enter__(self) -> Multiplexer:
        self.model_thread.start()
        log = self.stdout.open("a+", encoding="utf-8")
        self.process = subprocess.Popen(
            [sys.executable, "-m", "hermes_cli.main", "gateway", "run", "--quiet"], cwd=ROOT, env=self.env,
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 90
        while self.process.poll() is None and time.monotonic() < deadline:
            with contextlib.suppress(OSError, ValueError, AssertionError):
                self.identity = control(self.home, "identify", timeout=2)
                if self.identity.get("state") == "ready":
                    self._start_backend()
                    return self
            threading.Event().wait(.1)
        self.__exit__()
        raise AssertionError(f"multiplexer not ready: {self.log_text()[-4000:]}")

    def __exit__(self, *_exc) -> None:
        for process in (self.backend, self.process):
            if process is not None and process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        self.model.shutdown()
        self.model.server_close()
        self.model_thread.join(timeout=5)

    def log_text(self) -> str:
        paths = (self.stdout, self.home / "logs" / "gateway.log")
        return "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in paths if path.exists())

    def runtime_platforms(self) -> dict:
        path = self.home / "gateway_state.json"
        return json.loads(path.read_text(encoding="utf-8")).get("platforms", {}) if path.exists() else {}

    def routes(self) -> list[dict]:
        import hermes_yaml
        return hermes_yaml.safe_load((self.home / "config.yaml").read_text(encoding="utf-8")).get("profile_routes", [])

    def env_names(self) -> list[str]:
        path = self.home / ".env"
        lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
        return sorted(line.split("=", 1)[0] for line in lines if "=" in line and not line.startswith("#"))

    def _start_backend(self) -> None:
        token = uuid.uuid4().hex
        env = {**self.env, "HERMES_DASHBOARD_SESSION_TOKEN": token, "HERMES_DESKTOP_ISOLATED_BACKEND": "1"}
        output = self.stdout.with_name("serve.out")
        self.backend = subprocess.Popen(
            [sys.executable, "-m", "hermes_cli.main", "serve", "--host", "127.0.0.1", "--port", "0", "--skip-build"],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=output.open("w"), stderr=subprocess.STDOUT)
        ready = re.compile(r"HERMES_BACKEND_READY port=(\d+)")
        wait_until(lambda: ready.search(output.read_text(errors="replace")), timeout=90, interval=.2, what="serve ready")
        self.backend_url = f"ws://127.0.0.1:{ready.search(output.read_text(errors='replace'))[1]}/api/ws?token={token}"

    async def _rpc(self, method: str, params: dict) -> dict:
        async with connect(self.backend_url, max_size=None) as socket:
            await socket.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
            async with asyncio.timeout(90):
                while (reply := json.loads(await socket.recv())).get("id") != 1:
                    pass
        return reply

    def call(self, method: str, **params) -> dict:
        reply = asyncio.run(self._rpc(method, params))
        self.replies.append(reply)
        assert "result" in reply, (method, reply.get("error"))
        return reply["result"]

    def paste_token(self) -> None:
        item = self.call("vault.add", kind="api_key", label="Discord bot token", secret={"api_key": BOT_TOKEN})["id"]
        self.call("connectors.discord.token", item=item)

    def install_status(self) -> dict:
        return self.call("chat.install.status", provider_id="discord", workspace=GUILD_ID, profile=BOT)

    def run_wizard(self) -> dict:
        self.paste_token()
        result = self.call("chat.install.begin", provider_id="discord", workspace=GUILD_ID, profile=BOT)
        if result["state"]["step"] == "needs_owner":
            result = self.call("chat.install.advance", provider_id="discord", workspace=GUILD_ID, profile=BOT,
                               event="owner_confirmed", expected_revision=result["state"]["revision"],
                               owner_member_id="123456789012345678")
        return result

    def replies_text(self) -> str:
        return json.dumps(self.replies)

    def current_instance(self) -> str:
        return control(self.home, "identify")["instance_id"]

    def forget_adapter_token(self) -> None:
        path = self.home / ".env"
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        path.write_text("".join(line for line in lines if not line.startswith("DISCORD_BOT_TOKEN=")), encoding="utf-8")
        reply = control(self.home, "reload-platform", {
            "home": str(self.home), "platform": "discord", "env_keys": ["DISCORD_BOT_TOKEN"]}, timeout=30)
        assert reply["reloaded"], reply
