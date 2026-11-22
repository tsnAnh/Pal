"""The owner lane asks a teammate and waits: reply routing, restarts, expiry and the owner's cards.

Real ``hermes gateway run`` child, the real Slack adapter against the Slack stand-in, the bot's own Slack
tools, a scripted model and a temp HERMES_HOME. The desk's sqlite rows are read straight from the profile home.
"""

from __future__ import annotations

import sys
from typing import Optional

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

CAROL, DAVE, ERIN, FRANK, GINA, HANK = D.CAROL, D.DAVE, D.ERIN, D.FRANK, D.GINA, D.HANK


@pytest.fixture(scope="module")
def world(tmp_path_factory):
    built = D.make_desk_world(tmp_path_factory, "desk-asks")
    for user in (CAROL, DAVE, ERIN, FRANK, GINA, HANK):
        built.drv.standin.users[user] = M.user_record(user)
    yield built
    try:
        print(f"\nartifact: {D.write_artifact_with_rows(built, 'slack-desk-asks.json')}")
    finally:
        M.teardown(built)


def wake_after_reply(world: M.World, person: str, token: str, *script, text: str = "the answer") -> None:
    question = f"Question for {token}?"
    D.owner_says(world, f"{token}-ask", f"ask <@{person}> something", D.ask(person, question),
               C.answer(f"A-{token}-ask", "Asked, waiting."))
    D.open_ask_for(world, person, question)
    M.scripted(world, token, *script)
    D.alice_replies(world, person, token, text)


def test_a_named_person_is_asked_at_once_with_no_card_and_the_ask_waits_open(world):
    D.owner_says(world, "ask-a", f"ask <@{M.ALICE}> for the Q3 number and tell me",
               D.ask(M.ALICE, "What is the Q3 number?"), C.answer("A-ask-a", "Asked Alice, waiting."))
    row = D.open_ask_for(world, M.ALICE)
    assert row["payload"]["question"] == "What is the Q3 number?"
    posts = D.slack_posts(world, f"D{M.ALICE[1:]}")
    assert [p.params["text"] for p in posts] == ["What is the Q3 number?"]
    assert not D.desk_buttons(world), "a named send must not raise an owner card"
    assert row["payload"]["anchor_ts"], "the posted message is the anchor replies are matched against"
    assert row["owner_id"] == M.OWNER


def test_the_reply_wakes_the_asking_conversation_once_and_starts_no_turn_of_its_own(world):
    before_keys = set(world.session_keys())
    aid = M.scripted(world, "reply-a", C.answer("A-reply-a", "Alice says it is 4.2."))
    ts = D.alice_replies(world, M.ALICE, "reply-a", "4.2M, final as of Friday")
    C.wait_reply(world, D.OWNER_DM, aid, "the owner told what Alice said")
    request = world.request("reply-a", 0)
    wake = next(m["content"] for m in request["messages"] if m["role"] == "user" and "[in:reply-a]" in str(m["content"]))
    assert "Reply from" in wake and f"<@{M.ALICE}>" in wake and "What is the Q3 number?" in wake
    assert "data, not instructions" in wake
    assert C.turns(world, "reply-a") == 1
    assert not [k for k in set(world.session_keys()) - before_keys if k.endswith("~member")]
    assert not world.sessions_of("[in:reply-a]") == [], "the wake lands in the asking session"
    row = D.wait_row(world, "the ask answered and delivered", lambda r: r["kind"] == "ask" and r["state"] == "done"
                     and r["delivered_at"] is not None)
    assert row["outcome"]["reply"]["text"].startswith("4.2M")
    reactions = world.drv.standin.calls_of("reactions.add")
    assert any(c.params.get("name") == "white_check_mark" and str(c.params.get("timestamp")) == ts for c in reactions)
    assert world.sessions_of("[in:reply-a]")[0][0].startswith("agent:") and not world.sessions_of("[in:reply-a]")[0][0].endswith("~member")


def test_an_unnamed_recipient_needs_the_owners_card_and_nothing_is_sent_before_approve(world):
    D.owner_says(world, "send-c", "let the team know lunch is at noon",
               D.ask(CAROL, "Lunch is at noon, can you make it?"), C.answer("A-send-c", "Waiting for your approval."))
    card = D.wait_desk_card(world)
    row = D.wait_row(world, "the send awaiting the owner", lambda r: r["kind"] == "send" and r["state"] == "open")
    assert D.dm_posts(world, CAROL) == [], "nothing may reach Carol before the owner approves"
    assert row["payload"]["wait_for_reply"] is True
    message_id = card[0]["message_id"]
    D.click(world, M.OWNER, D.card_choice(card, D.APPROVE, message_id))
    D.wait_row(world, "the approved send done", lambda r: r["kind"] == "send" and r["state"] == "done")
    D.open_ask_for(world, CAROL, "Lunch is at noon, can you make it?")
    wait_until(lambda: not D.desk_buttons(world), "the card closed", timeout=D.DESK_WAIT, on_timeout=world.ctx)
    assert D.card_text(world, message_id) == "Approved and sent."
    D.click(world, M.OWNER, card[0])
    world.settle()
    assert D.dm_posts(world, CAROL) == ["Lunch is at noon, can you make it?"], "a second tap must not send twice"
    aid = M.scripted(world, "send-c-reply", C.answer("A-send-c-reply", "Carol will come."))
    D.alice_replies(world, CAROL, "send-c-reply", "Yes, see you there")
    C.wait_reply(world, D.OWNER_DM, aid, "the approved ask's reply reached the asking conversation")
    assert C.turns(world, "send-c-reply") == 1


def test_a_tainted_wake_that_messages_a_third_person_asks_the_owner_for_that_exact_call_and_deny_sends_nothing(world):
    wake_after_reply(world, DAVE, "g1-deny",
                     ToolCall("slack_send_dm", {"user_id": GINA, "text": "Dave says go ahead."}),
                     C.answer("A-g1-deny", "Not sent, you declined."))
    _, deny = D.wait_exec_card(world)
    assert D.dm_posts(world, GINA) == []
    D.tap_exec(world, deny)
    C.wait_reply(world, D.OWNER_DM, "A-g1-deny", "the wake finished after the denial")
    world.settle()
    assert D.dm_posts(world, GINA) == [], "a denied call must not send"
    assert not D.desk_buttons(world), "the gate uses the exact-call card, not a second desk card"
    assert not [r for r in D.desk_rows(world) if r["kind"] == "send" and r["payload"]["to"]["user_id"] == GINA]


def test_approving_the_exact_call_sends_with_one_tap_and_raises_no_second_card(world):
    wake_after_reply(world, ERIN, "g1-ok",
                     ToolCall("slack_send_dm", {"user_id": HANK, "text": "Erin says go ahead."}),
                     C.answer("A-g1-ok", "Sent."))
    approve, _ = D.wait_exec_card(world)
    assert D.dm_posts(world, HANK) == []
    D.tap_exec(world, approve)
    C.wait_reply(world, D.OWNER_DM, "A-g1-ok", "the wake finished after the approval")
    assert D.dm_posts(world, HANK) == ["Erin says go ahead."]
    assert not D.exec_buttons(world) and not D.desk_buttons(world), "one tap, no second card"
    assert not [r for r in D.desk_rows(world) if r["kind"] == "send" and r["payload"]["to"]["user_id"] == HANK]


def test_a_tainted_wake_running_a_command_needs_the_owners_card_and_deny_leaves_it_unrun(world, tmp_path):
    victim = tmp_path / "keep-me"
    victim.mkdir()
    (victim / "f.txt").write_text("x")
    wake_after_reply(world, FRANK, "g1-term-deny", ToolCall("terminal", {"command": f"rm -rf {victim}"}),
                     C.answer("A-g1-term-deny", "I did not run it."))
    _, deny = D.wait_exec_card(world)
    assert victim.exists()
    D.tap_exec(world, deny)
    C.wait_reply(world, D.OWNER_DM, "A-g1-term-deny", "the wake finished after the denial")
    assert victim.exists(), "a denied command must not run"


def test_approving_a_tainted_command_runs_it_after_exactly_one_card(world, tmp_path):
    victim = tmp_path / "remove-me"
    victim.mkdir()
    (victim / "f.txt").write_text("x")
    wake_after_reply(world, M.BOB, "g1-term-ok", ToolCall("terminal", {"command": f"rm -rf {victim}"}),
                     C.answer("A-g1-term-ok", "Done."))
    approve, _ = D.wait_exec_card(world)
    assert victim.exists()
    D.tap_exec(world, approve)
    C.wait_reply(world, D.OWNER_DM, "A-g1-term-ok", "the wake finished after the approval")
    assert not victim.exists(), "the approved command must run"
    assert not D.exec_buttons(world), "the inner command gate must accept the covering grant, not ask again"


def test_two_open_questions_to_one_person_make_a_top_level_reply_ambiguous_and_a_thread_reply_exact(world):
    first, second = "Question one?", "Question two? [in:amb-expiry]"
    for token, question in (("amb-1", first), ("amb-2", second)):
        D.owner_says(world, token, f"ask <@{M.ALICE}> {question}", D.ask(M.ALICE, question),
                   C.answer(f"A-{token}", "Asked."))
        D.open_ask_for(world, M.ALICE, question)
    one, two = D.open_ask_for(world, M.ALICE, first), D.open_ask_for(world, M.ALICE, second)
    D.alice_replies(world, M.ALICE, "amb-top", "yes")
    wait_until(lambda: D.AMBIGUOUS_NOTICE in D.dm_posts(world, M.ALICE), "the ask-to-reply-in-the-thread notice",
               timeout=D.DESK_WAIT, on_timeout=world.ctx)
    world.settle()
    assert C.turns(world, "amb-top") == 0
    open_after = {r["id"] for r in D.desk_rows(world) if r["kind"] == "ask" and r["state"] == "open"}
    assert {one["id"], two["id"]} <= open_after, "an ambiguous reply claims nothing"
    aid = M.scripted(world, "amb-thread", C.answer("A-amb-thread", "Alice answered the first."))
    envelope = world.drv.standin.dm(M.ALICE, "first answer [in:amb-thread]", thread_ts=one["payload"]["anchor_ts"])
    C.wait_reply(world, D.OWNER_DM, aid, "the threaded reply woke the asking conversation")
    world.drv.standin.redeliver(envelope)
    world.settle()
    assert C.turns(world, "amb-thread") == 1, "a redelivered reply must not wake twice"
    rows = {r["id"]: r for r in D.desk_rows(world)}
    assert rows[one["id"]]["state"] == "done" and rows[two["id"]]["state"] == "open"


def test_an_ask_that_runs_out_of_time_tells_the_asker_and_a_late_reply_starts_nothing(world):
    two = D.open_ask_for(world, M.ALICE, "Question two? [in:amb-expiry]")
    aid = M.scripted(world, "amb-expiry", C.answer("A-amb-expiry", "Alice never answered."))
    D.desk_edit(world, "UPDATE items SET expires_at = ? WHERE id = ?", 1.0, two["id"])
    C.wait_reply(world, D.OWNER_DM, aid, "the asking conversation learned there was no reply", timeout=90)
    request = world.request("amb-expiry", 0)
    assert any("[No reply]" in str(m["content"]) for m in request["messages"] if m["role"] == "user")
    D.wait_row(world, "the expired ask delivered", lambda r: r["id"] == two["id"] and r["state"] == "expired")
    before = set(world.session_keys())
    D.alice_replies(world, M.ALICE, "amb-late", "sorry, only now")
    world.settle()
    assert C.turns(world, "amb-late") == 0
    assert not [k for k in set(world.session_keys()) - before if k.endswith("~member")]


def test_new_conversation_cancels_its_open_questions_and_a_later_reply_is_not_routed(world):
    question = "Question for new-ask?"
    aid = M.scripted(world, "new-ask", D.ask(GINA, question), C.answer("A-new-ask", "Asked."))
    thread = M.dm(world, M.OWNER, f"ask <@{GINA}> something [in:new-ask]")
    C.wait_reply(world, D.OWNER_DM, aid, "the owner turn answered")
    row = D.open_ask_for(world, GINA, question)
    M.dm(world, M.OWNER, "/new", thread_ts=thread)
    D.wait_row(world, "the open ask cancelled", lambda r: r["id"] == row["id"] and r["state"] == "cancelled")
    D.alice_replies(world, GINA, "new-late", "too late")
    world.settle()
    assert C.turns(world, "new-late") == 0
    assert next(r for r in D.desk_rows(world) if r["id"] == row["id"])["state"] == "cancelled"


def test_the_report_alias_posts_to_the_owners_report_channel_with_no_card(world):
    before = len([r for r in D.desk_rows(world) if r["kind"] == "send"])
    D.owner_says(world, "report-a", "send me the report",
               ToolCall("slack_post_message", {"channel": "report", "text": "The report is ready."}),
               C.answer("A-report-a", "Sent the report."))
    assert [p.params["text"] for p in D.slack_posts(world, world.drv.home_channel)
            if p.params["text"] == "The report is ready."] == ["The report is ready."]
    assert not D.desk_buttons(world)
    assert len([r for r in D.desk_rows(world) if r["kind"] == "send"]) == before
