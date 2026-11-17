import pytest

from gateway import device_connectors, device_directory, device_registry
from gateway.session_controls import AuthorityConnection
from gateway.session_presence_controls import _authority_home
from tests.gateway.devices_harness import IPHONE, MAC_APP, call, make_authority, transport, write_profile_config

MAC_HELLO = {**MAC_APP, "model": "Mac16,8", "device_tools": True}


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    write_profile_config(tmp_path)
    return tmp_path


def connect(authority):
    return AuthorityConnection(authority, transport(), {"user_id": "owner"})


def types(root, authority):
    kinds = device_connectors.device_kinds(_authority_home(authority))
    return {record.device_id: (device_directory.type_of(record.kind, record.model), kinds.get(record.device_id))
            for record in device_registry.list_devices(root)}


@pytest.mark.asyncio
async def test_a_legacy_ios_hello_from_a_mac_never_downgrades_its_kind(root):
    authority = await make_authority(root)
    mac = connect(authority)
    assert (await call(mac, "client.hello", MAC_HELLO))["result"]["recorded"] is True
    assert (await call(mac, "client.hello", {**MAC_HELLO, "kind": "ios"}, rid=2))["result"]["recorded"] is True
    assert types(root, authority)[MAC_HELLO["device_id"]] == ("Mac", "mac")
    await mac.close()


@pytest.mark.asyncio
async def test_a_mac_row_stored_as_ios_heals_on_the_next_mac_hello(root):
    authority = await make_authority(root)
    mac, phone = connect(authority), connect(authority)
    await call(mac, "client.hello", {**MAC_HELLO, "kind": "ios"})
    await call(phone, "client.hello", {**IPHONE, "device_tools": True}, rid=2)
    assert types(root, authority)[MAC_HELLO["device_id"]][0] == "iPhone"
    await call(mac, "client.hello", MAC_HELLO, rid=3)
    listed = types(root, authority)
    assert listed[MAC_HELLO["device_id"]] == ("Mac", "mac")
    assert listed[IPHONE["device_id"]] == ("iPhone", "ios")
    await mac.close()
    await phone.close()
