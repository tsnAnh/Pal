import json
import threading
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from gateway import push_apns

KEY_ID = "ABC123DEFG"
TEAM_ID = "TEAM123456"
TOPIC = "dev.example.hermes"
APNS_TOKEN = "ab" * 32
IPHONE = {"kind": "ios", "device_id": "iphone-0001", "label": "iPhone", "app_version": "1.0 (7)",
          "model": "iPhone 16", "os": "iOS 26.1", "accepts_offers": True, "attention": "background"}
MAC_APP = {"kind": "mac", "device_id": "mac-app-0001", "label": "Mac", "app_version": "1.0 (7)",
           "model": "Mac14,2", "os": "macOS 26.1", "accepts_offers": True, "attention": "background"}
MAC = {"kind": "desktop", "device_id": "mac-desktop-01", "label": "Desktop (macOS)", "app_version": "2.0"}


@dataclass
class ApnsStub:
    private_pem: str
    public_pem: str
    responses: list = field(default_factory=lambda: [(200, {})])
    requests: list = field(default_factory=list)
    sleeps: list = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def handler(self, request: httpx.Request) -> httpx.Response:
        with self.lock:
            self.requests.append(request)
            status, body = self.responses[min(len(self.requests), len(self.responses)) - 1]
        return httpx.Response(status, json=body)

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)

    def payloads(self) -> list[dict]:
        return [json.loads(request.content) for request in self.requests]


def new_apns_stub() -> ApnsStub:
    key = ec.generate_private_key(ec.SECP256R1())
    private_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption()).decode()
    public_pem = key.public_key().public_bytes(serialization.Encoding.PEM,
                                               serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    return ApnsStub(private_pem, public_pem)


def install_apns_stub(monkeypatch, stub: ApnsStub) -> None:
    monkeypatch.setattr(push_apns, "_shared", None)
    monkeypatch.setattr(push_apns, "_retry_after", 0.0)
    monkeypatch.setattr(push_apns, "build_client", lambda config: push_apns.ApnsClient(
        config, transport=stub.transport(), sleep=stub.sleeps.append))


def configure_apns(root: Path, stub: ApnsStub, *, inline: bool = False) -> None:
    config = root / "config.yaml"
    existing = config.read_text(encoding="utf-8") if config.exists() else ""
    config.write_text(existing + f"push:\n  apns:\n    key_id: {KEY_ID}\n    team_id: {TEAM_ID}\n    topic: {TOPIC}\n",
                      encoding="utf-8")
    if inline:
        (root / ".env").write_text("APNS_AUTH_KEY=" + stub.private_pem.strip().replace("\n", "\\n") + "\n",
                                   encoding="utf-8")
        return
    key_file = root / "AuthKey_TEST.p8"
    key_file.write_text(stub.private_pem, encoding="utf-8")
    (root / ".env").write_text(f"APNS_AUTH_KEY_PATH={key_file}\n", encoding="utf-8")


def write_profile_config(home: Path, text: str = "") -> None:
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.yaml").write_text(text, encoding="utf-8")


def drain_push() -> None:
    from gateway import push_notify
    with push_notify._executor_lock:
        executor, push_notify._executor = push_notify._executor, None
    if executor is not None:
        executor.shutdown(wait=True)


async def make_authority(home: Path, runner=None, answer=None, *, register: bool = True):
    from gateway.config import GatewayConfig, Platform
    from gateway.session import SessionSource, SessionStore
    from gateway.session_authority import LiveSession, initialize_session_authority

    home.mkdir(parents=True, exist_ok=True)
    store = SessionStore(home / "sessions", GatewayConfig())
    if runner is None:
        runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=False), session_authorities=None)
    for name, value in (("_session_db", store._db), ("session_store", store), ("_draining", False),
                        ("_handle_message", answer), ("_adapter_for_source", lambda source: None)):
        if not hasattr(runner, name):
            setattr(runner, name, value)
    authority = await initialize_session_authority(runner, profile_id=str(home), instance_id="owner",
                                                   db=store._db, register=register)
    store._db.create_session("s", source="telegram")
    authority.sessions["s"] = LiveSession(SessionSource(platform=Platform.TELEGRAM, chat_id="c"), "s")
    return authority


def transport():
    return SimpleNamespace(desktop_local=False, closed=False, close=lambda: None)


async def call(connection, method, params=None, rid=1):
    return await connection.dispatch({"id": rid, "method": method, "params": params or {}})
