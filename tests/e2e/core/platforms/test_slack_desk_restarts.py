"""The owner desk across gateway restarts: a reply that arrived while down and rows a crash left half done.

Real ``hermes gateway run`` child stopped and started again on the same HERMES_HOME, the real Slack adapter against
the Slack stand-in and a scripted model. Rows are seeded into the profile's desk database only to put them in the
state a crash would have left; everything after the restart is the product's own recovery.
"""

from __future__ import annotations

import json
import sys
import time

import pytest

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms import _desk_rig as D
from tests.e2e.core.platforms import _member_rig as M
from tests.fakes.fake_llm_provider import ToolCall
from tests.fakes.platforms._standin import wait_until
from tests.fakes.platforms.slack_standin import TEAM_ID

pytestmark = [
    pytest.mark.spawns_gateway_lookalike,
    pytest.mark.skipif(sys.platform == "win32", reason="POSIX process-group gateway harness"),
]


@pytest.fixture(scope="module")
def world(tmp_path_factory):
    built = D.make_desk_world(tmp_path_factory, "desk-restarts")
    for user in (D.CAROL, D.DAVE, D.ERIN, D.FRANK):
        built.drv.standin.users[user] = M.user_record(user)
    yield built
    try:
        print(f"\nartifact: {D.write_artifact_with_rows(built, 'slack-desk-restarts.json')}")
    finally:
        M.teardown(built)


def restart(world: M.World) -> None:
    world.gw.stop()
    world.gw.start()


def test_a_reply_sent_while_the_gateway_was_down_is_found_on_reconnect_and_wakes_once(world):
    question = "Missed question?"
    D.owner_says(world, "miss-ask", f"ask <@{D.FRANK}> something", D.ask(D.FRANK, question),
                 C.answer("A-miss-ask", "Asked."))
    row = D.open_ask_for(world, D.FRANK, question)
    world.gw.stop()
    standin = world.drv.standin
    channel = f"D{D.FRANK[1:]}"
    standin._remember(channel, {"type": "message", "user": D.FRANK, "text": "Sent while you were away [in:miss-wake]",
                                "ts": standin.next_ts(), "team": TEAM_ID})
    aid = M.scripted(world, "miss-wake", C.answer("A-miss-wake", "Frank answered while I was down."))
    world.gw.start()
    C.wait_reply(world, D.OWNER_DM, aid, "the missed reply reached the asking conversation")
    done = D.wait_row(world, "the recovered ask answered", lambda r: r["id"] == row["id"] and r["state"] == "done")
    assert done["outcome"]["reply"]["text"].startswith("Sent while you were away")
    world.settle()
    assert C.turns(world, "miss-wake") == 1
    assert D.dm_posts(world, D.FRANK) == [question], "recovery must never repost the question"


def test_rows_a_crash_left_half_done_end_in_exactly_one_honest_outcome_and_nothing_is_sent_again(world):
    posting_q = "Posting question? [in:crash-posting]"
    D.owner_says(world, "cp-ask", f"ask <@{D.CAROL}> something", D.ask(D.CAROL, posting_q), C.answer("A-cp-ask", "Asked."))
    posting = D.open_ask_for(world, D.CAROL, posting_q)
    D.owner_says(world, "cd-ask", f"ask <@{D.DAVE}> something", D.ask(D.DAVE, "Done question?"),
                 C.answer("A-cd-ask", "Asked."))
    answered = D.open_ask_for(world, D.DAVE, "Done question?")
    D.owner_says(world, "cs-ask", "let the team know", D.ask(D.ERIN, "Send text [in:crash-send]"),
                 C.answer("A-cs-ask", "Waiting for your approval."))
    card = D.wait_desk_card(world)
    sending = D.wait_row(world, "the send awaiting the owner", lambda r: r["kind"] == "send" and r["state"] == "open")
    posts_before = {person: D.dm_posts(world, person) for person in (D.CAROL, D.DAVE, D.ERIN)}
    world.gw.stop()
    D.desk_edit(world, "UPDATE items SET state = 'posting', created_at = 1.0, expires_at = expires_at WHERE id = ?",
                posting["id"])
    reply = json.dumps({"reply": {"user_id": D.DAVE, "user_name": "Dave", "text": "Done answer [in:crash-done]",
                                  "ts": "1.1"}})
    D.desk_edit(world, "UPDATE items SET state = 'done', outcome_json = ?, settled_at = ?, delivered_at = NULL "
                       "WHERE id = ?", reply, time.time(), answered["id"])
    D.desk_edit(world, "UPDATE items SET state = 'executing' WHERE id = ?", sending["id"])
    scripts = {token: M.scripted(world, token, C.answer(f"A-{token}", f"handled {token}"))
               for token in ("crash-posting", "crash-done", "crash-send")}
    world.gw.start()
    for token, aid in scripts.items():
        C.wait_reply(world, D.OWNER_DM, aid, f"{token} reached its asking conversation")
    world.settle()
    assert {token: C.turns(world, token) for token in scripts} == {token: 1 for token in scripts}
    states = {r["id"]: r for r in D.desk_rows(world)}
    assert states[posting["id"]]["state"] == "unknown"
    assert states[sending["id"]]["state"] == "unknown"
    assert states[answered["id"]]["state"] == "done" and states[answered["id"]]["delivered_at"] is not None
    assert {person: D.dm_posts(world, person) for person in (D.CAROL, D.DAVE, D.ERIN)} == posts_before
    wait_until(lambda: not D.desk_buttons(world), "the stopped send's card closed", timeout=D.DESK_WAIT,
               on_timeout=world.ctx)
    assert "may or may not" in D.card_text(world, card[0]["message_id"])
