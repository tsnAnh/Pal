from __future__ import annotations

import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from hermes_cli.profiles import create_profile
from tui_gateway import server
from tui_gateway.contracts import METHODS

CREDENTIAL_FILES = (".env", "config.yaml", "auth.json")


@pytest.fixture
def home(monkeypatch, tmp_path):
    root = tmp_path / "hermes-home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    for var in ("DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DASHSCOPE_API_KEY", "ALIBABA_CODING_PLAN_API_KEY",
                "GOOGLE_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                "OPENROUTER_API_KEY", "OPENAI_API_KEY"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(server, "_hermes_home", root)
    create_profile("scout", no_alias=True, no_skills=True)
    return root


@pytest.fixture
def canary():
    return f"CANARY-{uuid.uuid4()}"


def rpc(method, params=None):
    return server.handle_request({"id": "1", "method": method, "params": params or {}})


def ok(method, params=None):
    response = rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params or {})
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def row(provider_id, profile=None):
    listing = ok("model.providers.list", {"profile": profile} if profile else {})
    return next(p for p in listing["providers"] if p["id"] == provider_id)


def credential_files(home) -> dict[str, bytes | None]:
    return {name: (home / name).read_bytes() if (home / name).exists() else None for name in CREDENTIAL_FILES}


def files_mentioning(home, needle: str) -> list[str]:
    return [str(path.relative_to(home)) for path in home.rglob("*")
            if path.is_file() and needle.encode() in path.read_bytes()]


class FakeLLM:
    """A loopback OpenAI-compatible endpoint: one scripted answer for every request, every request recorded."""

    def __init__(self):
        self.requests: list[dict] = []
        self.status = 200
        self.body: dict | str = completion("OK")
        self.hang = False
        self.release = threading.Event()
        self.arrived = threading.Event()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                payload = json.loads(self.rfile.read(length) or b"{}")
                owner.requests.append({"path": self.path, "authorization": self.headers.get("authorization"),
                                       "body": payload})
                owner.arrived.set()
                if owner.hang:
                    owner.release.wait(30)
                data = (owner.body if isinstance(owner.body, str) else json.dumps(owner.body)).encode()
                try:
                    self.send_response(owner.status)
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    pass

            def log_message(self, *args):
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_address[1]}/v1"

    def stop(self):
        self.release.set()
        self._server.shutdown()
        self._server.server_close()


def completion(content: str) -> dict:
    return {"id": "chatcmpl-1", "object": "chat.completion", "created": 1, "model": "m",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


def failure(message: str, *, type: str = "invalid_request_error", code: str | None = None) -> dict:
    return {"error": {"message": message, "type": type, "code": code}}


@pytest.fixture
def llm():
    fake = FakeLLM()
    yield fake
    fake.stop()
