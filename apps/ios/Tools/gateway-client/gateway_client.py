import argparse
import asyncio
import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.cookiejar import CookieJar

import websockets

SUBPROTOCOL = "hermes-gateway-v1"
TICKET_PREFIX = "hermes-gateway-ticket."
BOT_CHAT_TITLE = "Bot Chat"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Gateway:
    def __init__(self, base_url, username, password):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(CookieJar()))

    def post(self, path, body=None, token=None):
        headers = {"content-type": "application/json"}
        if token:
            headers["authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else b""
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method="POST")
        with self.opener.open(request, timeout=20) as response:
            return json.load(response)

    def access_token(self):
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(8)
        query = urllib.parse.urlencode({
            "code_challenge": challenge, "code_challenge_method": "S256",
            "redirect_uri": "http://127.0.0.1:9/callback", "state": state,
        })
        try:
            self.opener.open(f"{self.base_url}/auth/native/authorize?{query}", timeout=20)
        except urllib.error.HTTPError as error:
            if error.code != 302:
                raise
        login = self.post("/auth/password-login", {"provider": "basic", "username": self.username, "password": self.password})
        code = urllib.parse.parse_qs(urllib.parse.urlparse(login["next"]).query)["code"][0]
        return self.post("/auth/native/token", {"code": code, "code_verifier": verifier})["access_token"]

    def socket_url_and_protocols(self):
        ticket = self.post("/api/webapp/socket-ticket?socket=gateway", None, self.access_token())["ticket"]
        return self.base_url.replace("http", "ws", 1) + "/api/ws", [SUBPROTOCOL, TICKET_PREFIX + ticket]


class Rpc:
    def __init__(self, socket, events):
        self.socket = socket
        self.events = events
        self.pending = {}
        self.next_id = 1

    async def pump(self):
        async for raw in self.socket:
            frame = json.loads(raw)
            if "id" in frame and frame["id"] in self.pending:
                self.pending.pop(frame["id"]).set_result(frame)
            elif frame.get("method") == "event":
                await self.events.put(frame["params"])

    async def call(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        await self.socket.send(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}))
        frame = await asyncio.wait_for(future, 30)
        if "error" in frame:
            raise RuntimeError(f"{method}: {json.dumps(frame['error'])}")
        return frame["result"]


async def open_chat(rpc, profile):
    found = await rpc.call("session.list", {"profile": profile, "title": BOT_CHAT_TITLE, "include_hidden": True})
    rows = [row for row in found["sessions"] if row.get("title") == BOT_CHAT_TITLE]
    if rows:
        session_id = rows[0].get("resolved_id") or rows[0]["session_id"]
        await rpc.call("session.resume", {"profile": profile, "session_id": session_id})
        return session_id
    created = await rpc.call("session.create", {
        "profile": profile, "title": BOT_CHAT_TITLE, "hidden": True,
        "request_id": str(uuid.uuid4()), "source": "gui",
    })
    return created["session_id"]


async def submit(args, gateway):
    url, protocols = gateway.socket_url_and_protocols()
    events = asyncio.Queue()
    async with websockets.connect(url, subprotocols=protocols) as socket:
        rpc = Rpc(socket, events)
        pump = asyncio.create_task(rpc.pump())
        await events.get()
        session_id = await open_chat(rpc, args.profile)
        admission = await rpc.call("prompt.submit", {
            "profile": args.profile, "session_id": session_id, "text": args.text, "submission_id": str(uuid.uuid4()),
        })
        print(json.dumps({"admitted": True, "t": time.time(), "session_id": session_id, "status": admission.get("status")}), flush=True)
        deadline = asyncio.get_running_loop().time() + args.hold
        while (remaining := deadline - asyncio.get_running_loop().time()) > 0:
            try:
                event = await asyncio.wait_for(events.get(), remaining)
            except TimeoutError:
                break
            if event.get("type") == "message.complete":
                print(json.dumps({"completed": True, "t": time.time()}), flush=True)
                break
        pump.cancel()


async def call(args, gateway):
    url, protocols = gateway.socket_url_and_protocols()
    events = asyncio.Queue()
    async with websockets.connect(url, subprotocols=protocols) as socket:
        rpc = Rpc(socket, events)
        pump = asyncio.create_task(rpc.pump())
        await events.get()
        print(json.dumps(await rpc.call(args.method, json.loads(args.params)), indent=2, sort_keys=True))
        pump.cancel()


async def watch(args, gateway):
    url, protocols = gateway.socket_url_and_protocols()
    async with websockets.connect(url, subprotocols=protocols) as socket:
        async for raw in socket:
            print(raw, flush=True)


def main():
    parser = argparse.ArgumentParser(description="Drive a Hermes gateway as a second client")
    parser.add_argument("--base-url", default=os.environ.get("HERMES_IOS_TEST_BASE_URL"))  # health: allow HX002 -- test-harness login for the throwaway e2e gateway, not Hermes config; argv would expose the password in ps
    parser.add_argument("--username", default=os.environ.get("HERMES_IOS_TEST_USERNAME"))  # health: allow HX002 -- test-harness login for the throwaway e2e gateway, not Hermes config; argv would expose the password in ps
    parser.add_argument("--password", default=os.environ.get("HERMES_IOS_TEST_PASSWORD"))  # health: allow HX002 -- test-harness login for the throwaway e2e gateway, not Hermes config; argv would expose the password in ps
    commands = parser.add_subparsers(dest="command", required=True)
    submit_parser = commands.add_parser("submit", help="send a prompt to a bot's chat and stay attached until the turn ends")
    submit_parser.add_argument("--profile", required=True)
    submit_parser.add_argument("--text", required=True)
    submit_parser.add_argument("--hold", type=float, default=120)
    commands.add_parser("watch", help="print every frame the gateway sends")
    call_parser = commands.add_parser("call", help="call one canonical method and print its result")
    call_parser.add_argument("method")
    call_parser.add_argument("params", nargs="?", default="{}")
    args = parser.parse_args()
    if not (args.base_url and args.username and args.password):
        parser.error("base URL and credentials are required (HERMES_IOS_TEST_* or flags)")
    gateway = Gateway(args.base_url, args.username, args.password)
    handler = {"submit": submit, "watch": watch, "call": call}[args.command]
    try:
        asyncio.run(handler(args, gateway))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
