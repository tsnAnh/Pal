"""A native sign-in is bound to the device that holds it, so ``devices.forget`` can end it: the refresh
token stops rotating and the access token stops working, while other devices stay signed in."""
import sqlite3
import time

import pytest
from fastapi.testclient import TestClient

from gateway import device_registry
from gateway.session_controls import AuthorityConnection
from hermes_cli import web_server
from hermes_cli.dashboard_auth import clear_providers, native_flow, register_provider
from tests.gateway.devices_harness import IPHONE, MAC, call, make_authority, transport, write_profile_config
from tests.hermes_cli.conftest_dashboard_auth import StubAuthProvider
from tests.hermes_cli.test_dashboard_auth_native_flow import _make_pkce, _walk_native_login
from tests.waiting import wait_until

REDIRECT = "http://127.0.0.1:53999/cb"


@pytest.fixture
def gated_client():
    native_flow._reset_for_tests()
    clear_providers()
    register_provider(StubAuthProvider())
    state = web_server.app.state
    previous = {name: getattr(state, name, None) for name in ("bound_host", "bound_port", "auth_required")}
    state.bound_host, state.bound_port, state.auth_required = "fly-app.fly.dev", 443, True
    yield TestClient(web_server.app, base_url="https://fly-app.fly.dev", follow_redirects=False)
    native_flow._reset_for_tests()
    clear_providers()
    for name, value in previous.items():
        setattr(state, name, value)


def sign_in(client, device_id=None):
    verifier, challenge = _make_pkce()
    code, _state = _walk_native_login(client, redirect_uri=REDIRECT, challenge=challenge)
    body = {"code": code, "code_verifier": verifier}
    if device_id is not None:
        body["device_id"] = device_id
    response = client.post("/auth/native/token", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def refresh(client, tokens, device_id=None):
    body = {"refresh_token": tokens["refresh_token"], "provider": "stub"}
    if device_id is not None:
        body["device_id"] = device_id
    return client.post("/auth/native/refresh", json=body)


def bound_grants(root):
    conn = sqlite3.connect(root / device_registry.DB_NAME)
    try:
        return dict(conn.execute("SELECT refresh_digest, device_id FROM device_grants").fetchall())
    finally:
        conn.close()


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    write_profile_config(tmp_path)
    return tmp_path


def test_a_sign_in_is_bound_to_its_device_and_the_binding_follows_every_refresh(gated_client, root):
    tokens = sign_in(gated_client, IPHONE["device_id"])
    assert bound_grants(root) == {device_registry.digest(tokens["refresh_token"]): IPHONE["device_id"]}

    rotated = refresh(gated_client, tokens)
    assert rotated.status_code == 200, rotated.text
    assert bound_grants(root) == {device_registry.digest(rotated.json()["refresh_token"]): IPHONE["device_id"]}


def test_a_sign_in_without_a_device_id_binds_nothing_and_a_malformed_one_is_refused(gated_client, root):
    sign_in(gated_client)
    assert not (root / device_registry.DB_NAME).exists()
    verifier, challenge = _make_pkce()
    code, _state = _walk_native_login(gated_client, redirect_uri=REDIRECT, challenge=challenge)
    refused = gated_client.post("/auth/native/token", json={
        "code": code, "code_verifier": verifier, "device_id": "not a device id"})
    assert refused.status_code == 422


@pytest.mark.asyncio
async def test_forgetting_a_device_ends_its_sign_in_and_leaves_the_others_alone(gated_client, root):
    authority = await make_authority(root)
    phone_tokens = sign_in(gated_client, IPHONE["device_id"])
    signed_in_at = int(time.time())
    wait_until(lambda: int(time.time()) > signed_in_at, what="the stub provider to mint distinct tokens")
    mac_tokens = sign_in(gated_client, MAC["device_id"])
    wait_until(lambda: int(time.time()) > signed_in_at + 1, what="the stub provider to rotate to distinct tokens")
    phone_tokens = refresh(gated_client, phone_tokens).json()
    mac = AuthorityConnection(authority, transport(), {"user_id": "owner"})
    phone = AuthorityConnection(authority, transport(), {"user_id": "owner"})
    await call(mac, "client.hello", MAC)
    await call(phone, "client.hello", IPHONE)
    bearer = {"Authorization": f"Bearer {phone_tokens['access_token']}"}
    assert gated_client.get("/api/auth/me", headers=bearer).status_code == 200

    forgotten = await call(mac, "devices.forget", {"device_id": IPHONE["device_id"]}, rid=2)
    assert forgotten["result"] == {"forgotten": True, "grants_revoked": 1, "push_removed": False}

    after = refresh(gated_client, phone_tokens)
    assert after.status_code == 401 and after.json()["error"] == "session_expired"
    assert gated_client.get("/api/auth/me", headers=bearer).status_code == 401
    assert refresh(gated_client, mac_tokens).status_code == 200
    assert set(bound_grants(root).values()) == {MAC["device_id"]}
    await mac.close()
    await phone.close()
