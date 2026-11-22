"""A teammate's request the owner must approve: the card, the one-shot owner-lane run, decline, expiry and restarts.

Real ``hermes gateway run`` child with the workspace audience, the real Slack adapter against the Slack stand-in,
a scripted model and a temp HERMES_HOME.
"""

from __future__ import annotations

import sys

import pytest

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms import _desk_rig as D
from tests.e2e.core.platforms import _member_rig as M
from tests.fakes.fake_llm_provider import ToolCall
from tests.fakes.platforms._standin import wait_until

pytestmark = [
    pytest.mark.spawns_gateway_lookalike,
    pytest.mark.skipif(sys.platform == "win32", reason="POSIX process-group gateway harness"),
]

CHANNEL = "C0000CHN"


@pytest.fixture(scope="module")
def world(tmp_path_factory):
    built = D.make_desk_world(tmp_path_factory, "desk-handoff", audience={"policy": "workspace"})
    yield built
    try:
        print(f"\nartifact: {D.write_artifact_with_rows(built, 'slack-desk-handoff.json')}")
    finally:
        M.teardown(built)


def teammate_asks_the_owner(world: M.World, token: str, request: str) -> dict:
    aid = M.scripted(world, f"{token}-ask", ToolCall("request_owner_action", {"request": request, "why": "needs you"}),
                     C.answer(f"A-{token}-ask", "I asked the owner; nothing is done yet."))
    M.post(world, M.ALICE, CHANNEL, f"please do this [in:{token}-ask]")
    C.wait_reply(world, CHANNEL, aid, f"the teammate was told the owner was asked ({token})")
    return D.wait_row(world, f"the hand-off {token} waiting for the owner",
                      lambda r: r["kind"] == "handoff" and r["payload"]["request"] == request and r["state"] == "open")


def test_the_owner_sees_the_request_only_in_their_own_dm_and_approving_runs_it_once_in_the_owner_lane(world):
    request = "Restart the staging service [in:ho-run]"
    row = teammate_asks_the_owner(world, "ho-1", request)
    card = D.wait_desk_card(world)
    assert not D.desk_buttons(world, CHANNEL), "the card must not appear where the teammate can see it"
    assert row["owner_id"] == M.OWNER
    assert not world.sessions_of("[in:ho-run]"), "nothing may run before the owner approves"
    aid = M.scripted(world, "ho-run", C.answer("A-ho-run", "Restarted the staging service."))
    message_id = card[0]["message_id"]
    D.click(world, M.OWNER, D.card_choice(card, D.APPROVE, message_id))
    C.wait_reply(world, CHANNEL, aid, "the approved request ran and answered in the teammate's thread")
    D.wait_row(world, "the hand-off done", lambda r: r["id"] == row["id"] and r["state"] == "done")
    runs = world.sessions_of("[in:ho-run]")
    assert len(runs) == 1 and not runs[0][0].endswith("~member"), "one owner-lane turn, not a member turn"
    wake = next(m["content"] for m in world.request("ho-run", 0)["messages"]
                if m["role"] == "user" and "[in:ho-run]" in str(m["content"]))
    assert request in wake and "Owner-approved request" in wake
    wait_until(lambda: not D.desk_buttons(world), "the card closed", timeout=D.DESK_WAIT, on_timeout=world.ctx)
    assert D.card_text(world, message_id) == "Approved. The request is running."
    D.click(world, M.OWNER, card[0])
    world.settle()
    assert C.turns(world, "ho-run") == 1, "a second tap must not dispatch again"


def test_a_teammate_tapping_the_owners_card_changes_nothing(world):
    request = "Rotate the deploy key [in:ho-blocked]"
    row = teammate_asks_the_owner(world, "ho-2", request)
    card = D.wait_desk_card(world)
    handle = D.click(world, M.ALICE, D.card_choice(card, D.APPROVE))
    wait_until(lambda: world.drv.click_answered(handle), "the tap answered", timeout=D.DESK_WAIT, on_timeout=world.ctx)
    world.settle()
    assert C.turns(world, "ho-blocked") == 0
    assert next(r for r in D.desk_rows(world) if r["id"] == row["id"])["state"] == "open"
    D.click(world, M.OWNER, D.card_choice(card, D.DECLINE))
    wait_until(lambda: not D.desk_buttons(world), "the card closed", timeout=D.DESK_WAIT, on_timeout=world.ctx)


def test_declining_tells_the_teammate_once_and_rewrites_the_card(world):
    request = "Delete the old backups [in:ho-decline]"
    row = teammate_asks_the_owner(world, "ho-3", request)
    card = D.wait_desk_card(world)
    aid = M.scripted(world, "ho-decline", C.answer("A-ho-decline", "Your owner declined, so it will not be done."))
    D.click(world, M.OWNER, D.card_choice(card, D.DECLINE))
    C.wait_reply(world, CHANNEL, aid, "the teammate was told it was declined")
    world.settle()
    assert C.turns(world, "ho-decline") == 1
    wait_until(lambda: not D.desk_buttons(world), "the card closed", timeout=D.DESK_WAIT, on_timeout=world.ctx)
    assert D.card_text(world, card[0]["message_id"]) == "Declined."
    states = {r["id"]: r for r in D.desk_rows(world)}
    assert states[row["id"]]["state"] == "declined" and states[row["id"]]["delivered_at"] is not None
    request_body = world.request("ho-decline", 0)
    assert any("Owner declined" in str(m["content"]) for m in request_body["messages"] if m["role"] == "user")
    notified = world.sessions_of("[in:ho-decline]")
    assert len(notified) == 1 and notified[0][0].endswith("~member"), "a decline only tells the member lane"


def test_a_request_the_owner_never_answers_expires_with_one_notice_to_the_teammate(world):
    request = "Archive last year's channels [in:ho-expire]"
    row = teammate_asks_the_owner(world, "ho-4", request)
    card = D.wait_desk_card(world)
    aid = M.scripted(world, "ho-expire", C.answer("A-ho-expire", "Your owner did not answer in time."))
    D.desk_edit(world, "UPDATE items SET expires_at = ? WHERE id = ?", 1.0, row["id"])
    C.wait_reply(world, CHANNEL, aid, "the teammate was told the request expired", timeout=90)
    world.settle()
    assert C.turns(world, "ho-expire") == 1
    wait_until(lambda: not D.desk_buttons(world), "the card closed", timeout=D.DESK_WAIT, on_timeout=world.ctx)
    assert D.card_text(world, card[0]["message_id"]) == "Expired. Nothing was done."
    assert next(r for r in D.desk_rows(world) if r["id"] == row["id"])["state"] == "expired"


def test_an_approved_request_the_gateway_had_not_dispatched_before_a_restart_runs_exactly_once(world):
    request = "Clear the build cache [in:ho-restart]"
    row = teammate_asks_the_owner(world, "ho-5", request)
    D.wait_desk_card(world)
    world.gw.stop()
    D.desk_edit(world, "UPDATE items SET state = 'approved' WHERE id = ?", row["id"])
    aid = M.scripted(world, "ho-restart", C.answer("A-ho-restart", "Cleared the build cache."))
    world.gw.start()
    C.wait_reply(world, CHANNEL, aid, "the approved request ran after the restart", timeout=90)
    world.settle()
    assert C.turns(world, "ho-restart") == 1
    assert len(world.sessions_of("[in:ho-restart]")) == 1
    assert next(r for r in D.desk_rows(world) if r["id"] == row["id"])["state"] == "done"
