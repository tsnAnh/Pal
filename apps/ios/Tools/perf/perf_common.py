import asyncio
import importlib.util
import json
import os
import statistics
import time
import zlib
from pathlib import Path

PERF_DIR = Path(__file__).resolve().parent
IOS_DIR = PERF_DIR.parents[1]
REPO = IOS_DIR.parents[1]
BOT_CHAT_TITLE = "Bot Chat"
PROFILE_SIZES = {"bot-alpha": 200, "bot-beta": 2000}


def load_gateway_client():
    path = IOS_DIR / "Tools" / "gateway-client" / "gateway_client.py"
    spec = importlib.util.spec_from_file_location("perf_gateway_client", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def target_from_environment():
    env = os.environ
    return {
        "base_url": env["HERMES_IOS_TEST_BASE_URL"],  # health: allow HX002 -- throwaway e2e gateway login handed over by run-baseline, not Hermes config
        "username": env["HERMES_IOS_TEST_USERNAME"],  # health: allow HX002 -- throwaway e2e gateway login handed over by run-baseline, not Hermes config
        "password": env["HERMES_IOS_TEST_PASSWORD"],  # health: allow HX002 -- throwaway e2e gateway login handed over by run-baseline, not Hermes config
        "home": Path(env["HERMES_IOS_E2E_HOME"]),  # health: allow HX002 -- sandbox home of the throwaway e2e gateway, handed over by run-baseline
    }


def profile_directory(home, profile):
    return home if profile == "default" else home / "profiles" / profile


def summarize(values):
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "median": statistics.median(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "samples": values,
    }


class TimedRpc:
    def __init__(self, socket):
        self.socket = socket
        self.next_id = 1
        self.ignored_frames = 0
        self.ignored_bytes = 0

    async def call(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        frame = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        started = time.perf_counter()
        await self.socket.send(frame)
        while True:
            raw = await asyncio.wait_for(self.socket.recv(), 60)
            received = time.perf_counter()
            text = raw if isinstance(raw, str) else raw.decode()
            decoded = json.loads(text)
            if decoded.get("id") == request_id:
                break
            self.ignored_frames += 1
            self.ignored_bytes += len(text.encode())
        if "error" in decoded:
            raise RuntimeError(f"{method}: {json.dumps(decoded['error'])[:300]}")
        body = text.encode()
        return {
            "result": decoded["result"],
            "wall_ms": (received - started) * 1000,
            "bytes": len(body),
            "deflated_bytes": len(zlib.compress(body, 6)),
            "text": text,
        }


async def open_rpc(client, gateway):
    url, protocols = gateway.socket_url_and_protocols()
    socket = await client.websockets.connect(url, subprotocols=protocols, max_size=None)
    rpc = TimedRpc(socket)
    await asyncio.wait_for(socket.recv(), 30)
    return socket, rpc
