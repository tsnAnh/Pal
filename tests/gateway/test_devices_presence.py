"""The device list the iOS settings screen shows: presence declared with ``client.hello`` persists in an
install-wide registry that outlives the gateway, and ``devices.forget`` and ``push.*`` act on it."""
from datetime import datetime
from types import SimpleNamespace

import pytest

from gateway import device_registry
from gateway.session_controls import AuthorityConnection
from tests.gateway.devices_harness import (
    APNS_TOKEN, IPHONE, MAC, call, configure_apns, make_authority, new_apns_stub, transport, write_profile_config,
)


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    write_profile_config(tmp_path)
    return tmp_path


def connect(authority, identity=None, **transport_attrs):
    peer = transport()
    for name, value in transport_attrs.items():
        setattr(peer, name, value)
    return AuthorityConnection(authority, peer, {"user_id": "owner"} if identity is None else identity), peer


def epoch(stamp: str) -> float:
    return datetime.fromisoformat(stamp).timestamp()


def test_a_symbolic_profile_id_never_roots_the_registry_in_the_working_directory(root, monkeypatch):
    elsewhere = root / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)
    assert {device_registry.install_root(home) for home in ("fixture", "p", "", None)} == {root}
    assert device_registry.install_root(str(root / "profiles" / "alpha")) == root


@pytest.mark.asyncio
async def test_hello_from_ios_and_desktop_lists_both_online_then_survives_a_gateway_restart(root):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    desktop, _ = connect(authority)
    await call(ios, "client.hello", IPHONE)
    await call(desktop, "client.hello", MAC, rid=2)

    listed = (await call(ios, "devices.list", {}, rid=3))["result"]["devices"]
    by_id = {row["device_id"]: row for row in listed}
    assert set(by_id) == {IPHONE["device_id"], MAC["device_id"]}
    assert by_id[IPHONE["device_id"]] == {
        "device_id": IPHONE["device_id"], "kind": "ios", "label": "iPhone", "model": "iPhone 16", "os": "iOS 26.1",
        "this_device": True, "online": True, "last_seen_at": by_id[IPHONE["device_id"]]["last_seen_at"],
        "push_enabled": False}
    assert by_id[MAC["device_id"]]["online"] is True and by_id[MAC["device_id"]]["this_device"] is False
    assert "model" not in by_id[MAC["device_id"]] and by_id[MAC["device_id"]]["label"] == "Desktop (macOS)"

    await ios.close()
    await desktop.close()
    persisted = {record.device_id: record for record in device_registry.list_devices(root)}

    restarted = await make_authority(root)
    observer, _ = connect(restarted)
    after = (await call(observer, "devices.list", {}))["result"]["devices"]
    assert {row["device_id"]: row["online"] for row in after} == {IPHONE["device_id"]: False, MAC["device_id"]: False}
    for row in after:
        assert epoch(row["last_seen_at"]) == pytest.approx(persisted[row["device_id"]].last_seen_at, abs=1.0)
        assert row["this_device"] is False
    await observer.close()


@pytest.mark.asyncio
async def test_a_second_profile_sees_every_device_and_its_live_presence(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    write_profile_config(tmp_path)
    runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=False), session_authorities=[])
    alpha = await make_authority(tmp_path / "profiles" / "alpha", runner, register=False)
    beta = await make_authority(tmp_path / "profiles" / "beta", runner, register=False)
    runner.session_authorities.extend([alpha, beta])
    phone, _ = connect(alpha)
    laptop, _ = connect(beta)
    await call(phone, "client.hello", IPHONE)
    await call(laptop, "client.hello", MAC)

    seen_from_beta = (await call(laptop, "devices.list", {}, rid=2))["result"]["devices"]
    assert {row["device_id"]: row["online"] for row in seen_from_beta} == {
        IPHONE["device_id"]: True, MAC["device_id"]: True}
    assert [row["this_device"] for row in seen_from_beta if row["device_id"] == MAC["device_id"]] == [True]
    assert device_registry.install_root(beta.profile_id) == tmp_path
    await phone.close()
    await laptop.close()


@pytest.mark.asyncio
async def test_forget_drops_the_row_push_token_and_live_connection_of_another_device(root):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    aborted = []
    desktop, _ = connect(authority, abort=lambda: aborted.append(True))
    await call(ios, "client.hello", IPHONE)
    await call(desktop, "client.hello", MAC)
    await call(desktop, "push.register", {
        "device_id": MAC["device_id"], "apns_token": APNS_TOKEN, "environment": "sandbox", "bundle_id": "dev.example.hermes"})

    forgotten = await call(ios, "devices.forget", {"device_id": MAC["device_id"]}, rid=3)
    assert forgotten["result"] == {"forgotten": True, "grants_revoked": 0, "push_removed": True}
    assert aborted == [True]
    listed = (await call(ios, "devices.list", {}, rid=4))["result"]["devices"]
    assert [row["device_id"] for row in listed] == [IPHONE["device_id"]]
    assert device_registry.push_targets(root) == []

    unknown = await call(ios, "devices.forget", {"device_id": "never-seen-0001"}, rid=5)
    assert unknown["result"] == {"forgotten": False, "grants_revoked": 0, "push_removed": False}
    await ios.close()
    await desktop.close()


@pytest.mark.asyncio
async def test_a_device_cannot_forget_itself_without_confirming(root):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    await call(ios, "client.hello", IPHONE)
    await call(ios, "push.register", {
        "device_id": IPHONE["device_id"], "apns_token": APNS_TOKEN, "environment": "production",
        "bundle_id": "dev.example.hermes"})

    refused = await call(ios, "devices.forget", {"device_id": IPHONE["device_id"]}, rid=3)
    assert refused["error"]["message"] == "confirm_required", refused
    assert device_registry.get_device(root, IPHONE["device_id"]) is not None

    confirmed = await call(ios, "devices.forget", {"device_id": IPHONE["device_id"], "confirm_self": True}, rid=4)
    assert confirmed["result"] == {"forgotten": True, "grants_revoked": 0, "push_removed": True}
    assert device_registry.get_device(root, IPHONE["device_id"]) is None
    await ios.close()


@pytest.mark.asyncio
async def test_a_read_only_connection_lists_devices_but_cannot_forget_or_register(root):
    authority = await make_authority(root)
    owner, _ = connect(authority)
    await call(owner, "client.hello", IPHONE)
    viewer, _ = connect(authority, {"user_id": "owner", "capabilities": ["session:read"]})
    await call(viewer, "client.hello", MAC)

    assert len((await call(viewer, "devices.list", {}, rid=2))["result"]["devices"]) == 2
    forget = await call(viewer, "devices.forget", {"device_id": IPHONE["device_id"]}, rid=3)
    register = await call(viewer, "push.register", {
        "device_id": MAC["device_id"], "apns_token": APNS_TOKEN, "environment": "sandbox", "bundle_id": "dev.example.hermes"}, rid=4)
    assert forget["error"]["message"] == register["error"]["message"] == "permission_denied"
    assert device_registry.get_device(root, IPHONE["device_id"]) is not None

    stranger, _ = connect(authority, {})
    assert (await call(stranger, "devices.list", {}))["error"]["message"] == "permission_denied"
    for connection in (owner, viewer, stranger):
        await connection.close()


REGISTER = {"device_id": IPHONE["device_id"], "apns_token": APNS_TOKEN, "environment": "sandbox",
            "bundle_id": "dev.example.hermes"}


@pytest.mark.asyncio
@pytest.mark.parametrize("override", [
    {"apns_token": "not-hex"}, {"apns_token": "ab" * 8}, {"environment": "staging"}, {"bundle_id": "bad bundle"},
    {"device_id": "x"}, {"extra": 1}])
async def test_push_register_refuses_malformed_params(root, override):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    await call(ios, "client.hello", IPHONE)
    reply = await call(ios, "push.register", {**REGISTER, **override}, rid=2)
    assert "error" in reply, reply
    assert device_registry.push_targets(root) == []
    await ios.close()


@pytest.mark.asyncio
async def test_push_register_needs_hello_and_only_ever_registers_the_declared_device(root):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    before_hello = await call(ios, "push.register", REGISTER)
    assert before_hello["error"]["message"] == "hello_required"
    await call(ios, "client.hello", IPHONE, rid=2)
    other = await call(ios, "push.register", {**REGISTER, "device_id": MAC["device_id"]}, rid=3)
    assert other["error"]["message"] == "device_mismatch"
    assert device_registry.push_targets(root) == []
    await ios.close()


@pytest.mark.asyncio
async def test_a_stored_token_reads_as_push_enabled_only_while_the_install_has_apns_credentials(root):
    authority = await make_authority(root)
    ios, _ = connect(authority)
    await call(ios, "client.hello", IPHONE)
    registered = await call(ios, "push.register", {**REGISTER, "apns_token": APNS_TOKEN.upper()}, rid=2)
    assert registered["result"] == {"registered": True, "push_enabled": False}
    assert device_registry.push_targets(root)[0].token == APNS_TOKEN
    row = (await call(ios, "devices.list", {}, rid=3))["result"]["devices"][0]
    assert row["push_enabled"] is False

    configure_apns(root, new_apns_stub())
    row = (await call(ios, "devices.list", {}, rid=4))["result"]["devices"][0]
    assert row["push_enabled"] is True
    assert (await call(ios, "push.register", REGISTER, rid=5))["result"]["push_enabled"] is True

    assert (await call(ios, "push.unregister", {"device_id": IPHONE["device_id"]}, rid=6))["result"] == {"removed": True}
    assert (await call(ios, "push.unregister", {"device_id": IPHONE["device_id"]}, rid=7))["result"] == {"removed": False}
    assert (await call(ios, "devices.list", {}, rid=8))["result"]["devices"][0]["push_enabled"] is False
    await ios.close()


@pytest.mark.asyncio
async def test_registering_a_token_on_a_new_device_id_takes_it_from_the_stale_row(root):
    authority = await make_authority(root)
    old, _ = connect(authority)
    await call(old, "client.hello", IPHONE)
    await call(old, "push.register", REGISTER)
    reinstalled, _ = connect(authority)
    await call(reinstalled, "client.hello", {**IPHONE, "device_id": "iphone-0002"})
    await call(reinstalled, "push.register", {**REGISTER, "device_id": "iphone-0002"}, rid=2)
    assert [target.device_id for target in device_registry.push_targets(root)] == ["iphone-0002"]
    await old.close()
    await reinstalled.close()
