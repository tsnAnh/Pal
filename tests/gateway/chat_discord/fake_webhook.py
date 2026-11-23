from __future__ import annotations

import json
from dataclasses import dataclass, field

import httpx

WEBHOOK_ID = "400000000000000001"
TOKEN = "FAKE-WEBHOOK-TOKEN-NOT-REAL-0123456789"
URL = f"https://discord.com/api/webhooks/{WEBHOOK_ID}/{TOKEN}"
CHANNEL_ID = "500000000000000001"
THREAD_ID = "500000000000000009"


@dataclass(frozen=True)
class Endpoint:
    bot: str = "pal"
    channel_id: str = CHANNEL_ID
    webhook_id: str = WEBHOOK_ID
    url: str = field(default=URL, repr=False)
    username: str | None = "Pal Helper"
    avatar_url: str | None = f"https://cdn.discordapp.com/avatars/{WEBHOOK_ID}/a1b2c3.png"


class FakeWebhookApi:
    def __init__(self):
        self.requests: list[httpx.Request] = []
        self.script: list[httpx.Response] = []
        self.sequence = 0
        self.transport = httpx.MockTransport(self.handler)

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.script:
            return self.script.pop(0)
        if request.method == "DELETE":
            return httpx.Response(204)
        self.sequence += 1
        body = {"id": f"6{self.sequence:017d}", "content": "", "attachments": []}
        if request.headers.get("content-type", "").startswith("multipart/"):
            body["attachments"] = [{"id": "1", "filename": "report.txt"}]
        return httpx.Response(200, json=body)

    def json_body(self, index: int = -1) -> dict:
        return json.loads(self.requests[index].content)


def error(status: int, code: int | None, **extra) -> httpx.Response:
    body = {"message": "x", **extra}
    if code is not None:
        body["code"] = code
    return httpx.Response(status, json=body)
