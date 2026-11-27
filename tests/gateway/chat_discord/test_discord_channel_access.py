from __future__ import annotations

import threading
import time

import pytest

from tests.gateway.chat_discord.discord_kit import BOT, Kit
from tests.gateway.chat_discord.fake_discord import BOT_ID, BOT_ROLE_ID, GUILD_ID, OWNER_ID, TOKEN
from tui_gateway.contracts import chat_provider as wire

ACCESS = wire.ChannelAccessState
VIEW, SEND, ADMINISTRATOR = 1 << 10, 1 << 11, 1 << 3
ROLE, MEMBER = 0, 1


def installed(kit: Kit):
    kit.allow_owner(OWNER_ID)
    service = kit.service()
    service.begin(BOT, "discord", GUILD_ID)
    return service, service.status(BOT, "discord", GUILD_ID)[1]


def overwrite(target: str, kind: int, *, allow: int = 0, deny: int = 0) -> dict:
    return {"id": target, "type": kind, "allow": str(allow), "deny": str(deny)}


def home_access(kit: Kit, *overwrites: dict) -> wire.ChannelAccessState:
    service, installation = installed(kit)
    kit.fake.channels[kit.home_channel()]["permission_overwrites"] = list(overwrites)
    return service.live_channels(installation)[0].access


def test_every_chosen_channel_is_reported_by_name(kit):
    service, installation = installed(kit)
    extra = kit.fake.add_channel("second-room")
    service.join(BOT, "discord", GUILD_ID, extra, False)
    kit.fake.add_channel("not-chosen")
    found = service.live_channels(installation)
    assert [(c.channel_id, c.access) for c in found] == [(kit.home_channel(), ACCESS.ok), (extra, ACCESS.ok)]
    assert found[1].name == "second-room"


@pytest.mark.parametrize(("overwrites", "expected"), [
    ([overwrite(BOT_ROLE_ID, ROLE, deny=VIEW)], ACCESS.cannot_view),
    ([overwrite(GUILD_ID, ROLE, deny=VIEW)], ACCESS.cannot_view),
    ([overwrite(BOT_ID, MEMBER, deny=SEND)], ACCESS.cannot_send),
    ([overwrite(GUILD_ID, ROLE, deny=VIEW | SEND), overwrite(BOT_ROLE_ID, ROLE, allow=VIEW | SEND)], ACCESS.ok),
    ([overwrite(BOT_ROLE_ID, ROLE, deny=SEND), overwrite(BOT_ID, MEMBER, allow=SEND)], ACCESS.ok),
    ([overwrite("999999999999999999", ROLE, deny=VIEW)], ACCESS.ok),
], ids=["role-hides", "everyone-hides", "member-mutes", "role-beats-everyone", "member-beats-role", "other-role"])
def test_channel_overwrites_apply_in_discord_order(kit, overwrites, expected):
    assert home_access(kit, *overwrites) is expected


def test_a_server_wide_missing_send_permission_is_reported(kit):
    service, installation = installed(kit)
    kit.fake.permissions &= ~SEND
    assert service.live_channels(installation)[0].access is ACCESS.cannot_send


def test_an_administrator_is_never_locked_out(kit):
    kit.fake.permissions |= ADMINISTRATOR
    assert home_access(kit, overwrite(BOT_ROLE_ID, ROLE, deny=VIEW)) is ACCESS.ok


def test_a_deleted_channel_is_unknown(kit):
    service, installation = installed(kit)
    kit.fake.delete_channel(kit.home_channel())
    assert [c.access for c in service.live_channels(installation)] == [ACCESS.unknown]


def test_the_check_only_reads(kit):
    service, installation = installed(kit)
    before = len(kit.fake.requests)
    service.live_channels(installation)
    assert {r.method for r in kit.fake.requests[before:]} == {"GET"}


@pytest.mark.parametrize("fault", ["reject_auth", "network_down", "server_error"])
def test_a_failed_check_is_unknown_and_carries_no_provider_text_or_token(kit, fault, caplog):
    service, installation = installed(kit)
    setattr(kit.fake, fault, True)
    found = service.live_channels(installation)
    assert [(c.channel_id, c.access) for c in found] == [(kit.home_channel(), ACCESS.unknown)]
    said = "".join(c.model_dump_json() for c in found) + caplog.text
    assert TOKEN not in said and "Unauthorized" not in said


def test_a_missing_token_is_unknown(kit):
    service, installation = installed(kit)
    kit.token = None
    assert [c.access for c in service.live_channels(installation)] == [ACCESS.unknown]


def test_a_slow_discord_ends_the_check_as_unknown(kit):
    service, installation = installed(kit)
    release = threading.Event()
    answer = kit.fake.route_member

    def stalled(body, **path):
        release.wait(10)
        return answer(body, **path)

    kit.fake.route_member = stalled
    kit.provider.channel_check_timeout_s = 0.2
    started = time.monotonic()
    try:
        found = service.live_channels(installation)
    finally:
        release.set()
    assert [c.access for c in found] == [ACCESS.unknown]
    assert time.monotonic() - started < 5


def test_nothing_is_checked_without_an_installation(kit):
    assert kit.service().live_channels(None) is None
