from __future__ import annotations

import sys

import pytest

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms import _member_rig as M
from tests.fakes.platforms._standin import wait_until

pytestmark = [
    pytest.mark.spawns_gateway_lookalike,
    pytest.mark.skipif(sys.platform == "win32", reason="POSIX process-group gateway harness"),
]

CHANNEL, SHARED = "C0000CHN", "C0000SHR"


def world_fixture(label: str, audience):
    @pytest.fixture(scope="module")
    def build(tmp_path_factory):
        built = M.make_world(tmp_path_factory, label, audience=audience)
        yield built
        try:
            print(f"\nartifact: {M.write_artifact(built, f'slack-member-{label}.json')}")
        finally:
            M.teardown(built)
    return build


workspace = world_fixture("ws", {"policy": "workspace"})
guests = world_fixture("guests", {"policy": "workspace", "include_restricted": True})
unconfigured = world_fixture("absent", None)


def serves(world: M.World, user: str, token: str, *, channel: str = CHANNEL, **extra) -> None:
    aid = M.scripted(world, token)
    M.post(world, user, channel, f"hello [in:{token}]", **extra)
    C.wait_reply(world, channel, aid, f"{user} served")
    (key, _), = world.sessions_of(f"[in:{token}]")
    assert key.endswith(":~member")


def test_slack_connect_external_user_is_refused_while_a_teammate_in_the_same_channel_is_served(workspace):
    external = {"team": M.EXTERNAL_TEAM, "user_team": M.EXTERNAL_TEAM, "is_ext_shared_channel": True}
    M.post(workspace, M.EXTERNAL, SHARED, "hello from another org [in:external]", **external)
    M.assert_no_turn(workspace, "external")
    serves(workspace, M.ALICE, "teammate", channel=SHARED)
    assert not [v for v in workspace.drv.visible(SHARED) if "external" in v.text]


def test_a_sender_whose_workspace_cannot_be_proven_is_never_admitted(workspace):
    M.post(workspace, M.BLIND, CHANNEL, "who am i [in:blind]", team=None)
    M.assert_no_turn(workspace, "blind")


def test_a_restricted_guest_is_refused_unless_the_owner_includes_guests(workspace, guests):
    M.post(workspace, M.GUEST, CHANNEL, "guest here [in:guest-refused]")
    M.assert_no_turn(workspace, "guest-refused")
    serves(guests, M.GUEST, "guest-admitted")


def test_an_install_without_an_audience_block_drops_member_messages_exactly_as_before(unconfigured):
    M.post(unconfigured, M.ALICE, CHANNEL, "anyone [in:legacy-channel]")
    M.dm(unconfigured, M.ALICE, "anyone in dm [in:legacy-dm]")
    M.assert_no_turn(unconfigured, "legacy-channel")
    assert C.turns(unconfigured, "legacy-dm") == 0
    assert not [v for v in unconfigured.drv.visible(CHANNEL)]
    aid = M.scripted(unconfigured, "legacy-owner")
    owner_dm = f"D{M.OWNER[1:]}"
    M.dm(unconfigured, M.OWNER, "owner still works [in:legacy-owner]")
    C.wait_reply(unconfigured, owner_dm, aid)
    names = M.tool_names(unconfigured.request("legacy-owner", 0))
    assert "terminal" in names
    assert not any(key.endswith(":~member") for key in unconfigured.session_keys())
