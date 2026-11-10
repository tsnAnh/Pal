import pytest

from tests.gateway.devices_harness import (
    call, configure_apns, drain_push, install_apns_stub, make_authority, new_apns_stub, write_profile_config,
)
from tests.gateway.test_push_notifications import finish_turn, phone_with_push


@pytest.fixture
def stub(monkeypatch):
    stub = new_apns_stub()
    install_apns_stub(monkeypatch, stub)
    yield stub
    drain_push()


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    title: Atlas\n", encoding="utf-8")
    return tmp_path


@pytest.mark.asyncio
@pytest.mark.parametrize("reply", ["[SILENT]", "  [SILENT]\n", "NO_REPLY"])
async def test_a_turn_that_ends_in_the_silence_marker_sends_no_alert(root, stub, reply):
    write_profile_config(root)
    configure_apns(root, stub)

    async def silent(event):
        return reply

    authority = await make_authority(root, answer=silent)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone)
    assert stub.requests == []
    await phone.close()

