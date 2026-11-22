"""Who the Slack tools may message without the owner, and how a waiting ask is recorded (tools/slack_outbound.py).

The owner lane of Slack sends at once to the people the owner named and to the owner; everyone else, and every
turn made of someone else's words, needs the owner's card. Pal and other platforms keep the one-card-per-send
path. A waiting ask is reserved before the post and is never posted twice.
"""

import json
from urllib.parse import parse_qs

import httpx
import pytest

from gateway.audience import Audience
from gateway.chat_slack.api import SlackApi
from gateway.config import Platform
from gateway.desk import ItemKind, ItemState
from gateway.desk.service import Desk
from gateway.platforms.event import MessageEvent
from gateway.session import SessionSource, build_session_key
from gateway.session_context import clear_session_vars, set_session_vars
from tools import approval, mcp_action_gate, slack_tools
from tools.approval_context import set_current_observability_context

TOKEN = "fake-token-do-not-use"
TEAM = "T0TEAM"
OWNER, ALICE, BOB = "U0OWNER", "U0ALICE", "U0BOB"
INSTALL = slack_tools.SlackInstall(TEAM, "Acme", "vault-item-1")
OPEN, OPENED = ItemState.OPEN, "ok"


class Calls(list):
    def __init__(self):
        super().__init__()
        self.refuse: list[str] = []


@pytest.fixture
def slack(monkeypatch):
    calls = Calls()

    def handle(request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        data = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        calls.append((method, data))
        if method == "users.info":
            return httpx.Response(200, json={"ok": True, "user": {
                "id": data["user"], "name": data["user"].lower(), "team_id": TEAM,
                "profile": {"display_name": data["user"].title()}}})
        if method == "conversations.open":
            return httpx.Response(200, json={"ok": True, "channel": {"id": "D" + data["users"][1:]}})
        if method == "conversations.info":
            return httpx.Response(200, json={"ok": True, "channel": {"id": data["channel"], "name": "general"}})
        if method == "chat.postMessage":
            if calls.refuse:
                error = calls.refuse.pop(0)
                if error == "network_failure":
                    raise httpx.ConnectError("down")
                return httpx.Response(200, json={"ok": False, "error": error})
            return httpx.Response(200, json={"ok": True, "ts": f"9.{len(calls)}", "channel": data["channel"]})
        raise AssertionError(f"unexpected Slack method {method}")

    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: INSTALL)
    monkeypatch.setattr(slack_tools, "_bot_token", lambda install: TOKEN)
    monkeypatch.setattr(slack_tools, "_api", lambda: SlackApi(httpx.MockTransport(handle), sleep=lambda s: None))
    monkeypatch.setenv("SLACK_ALLOWED_USERS", OWNER)
    monkeypatch.setenv("SLACK_HOME_CHANNEL", "D0REPORT")
    return calls


@pytest.fixture
def legacy_cards(monkeypatch):
    cards: list[dict] = []
    monkeypatch.setattr(mcp_action_gate, "approver_present", lambda: True)

    def request_draft_approval(**card):
        cards.append(card)
        return {"approved": True}

    monkeypatch.setattr(approval, "request_draft_approval", request_draft_approval)
    return cards


@pytest.fixture
def turn():
    tokens: list = []

    def enter(*, platform="slack", audience=Audience.OWNER, actor=OWNER, internal=False, tainted=False,
              named=(), cron=False, call_id="call-1"):
        source = SessionSource(platform=Platform(platform), chat_id="D0OWNER", chat_type="dm", user_id=actor,
                               scope_id=TEAM, thread_id="1.0", audience=audience)
        event = MessageEvent(text="go", source=source, internal=internal, carries_member_content=tainted,
                             named_user_ids=tuple(named))
        tokens.append(set_session_vars(
            platform=platform, chat_id="D0OWNER", chat_type="dm", user_id=actor, scope_id=TEAM,
            session_key=build_session_key(source), actor_id=actor, turn_event=event,
            cron_session="1" if cron else ""))
        set_current_observability_context(turn_id="turn-1", tool_call_id=call_id, session_id="sess-1")

    yield enter
    for token in tokens:
        clear_session_vars(token)
    set_current_observability_context()


def run(tool: str, args: dict) -> dict:
    return json.loads(slack_tools.run_slack_tool(tool, slack_tools._TOOLS[tool][0], args))


def posts(slack) -> list[dict]:
    return [data for method, data in slack if method == "chat.postMessage"]


def rows(kind: ItemKind) -> list:
    return Desk.in_turn().store.listing(frozenset(ItemState), frozenset({kind}))


def test_a_person_the_owner_named_is_messaged_at_once_with_no_card(slack, turn, legacy_cards):
    turn(named=(ALICE,))
    result = run("slack_send_dm", {"user_id": ALICE, "text": "Lunch?"})
    assert result["sent"] is True and [p["text"] for p in posts(slack)] == ["Lunch?"]
    assert legacy_cards == [] and rows(ItemKind.SEND) == []


def test_a_person_the_owner_did_not_name_waits_for_the_owner_card_and_nothing_is_posted(slack, turn, legacy_cards):
    turn(named=(BOB,))
    result = run("slack_send_dm", {"user_id": ALICE, "text": "Lunch?"})
    assert result["pending_owner_approval"] is True and result["sent"] is False
    assert posts(slack) == [] and legacy_cards == []
    (item,) = rows(ItemKind.SEND)
    assert item.state is OPEN and item.payload.to.user_id == ALICE and item.payload.text == "Lunch?"


def test_a_turn_made_of_someone_elses_words_never_sends_at_once_even_to_a_named_person(slack, turn):
    turn(named=(ALICE,), internal=True, tainted=True, actor="")
    assert run("slack_send_dm", {"user_id": ALICE, "text": "Lunch?"})["pending_owner_approval"] is True
    assert posts(slack) == []


def test_a_member_lane_send_always_waits_for_the_owner(slack, turn):
    turn(audience=Audience.MEMBER, actor=ALICE, named=(BOB,))
    assert run("slack_send_dm", {"user_id": BOB, "text": "hi"})["pending_owner_approval"] is True
    assert posts(slack) == []


def test_the_owner_and_the_report_channel_are_never_gated_for_a_member_turn_that_is_not_the_member_lane(slack, turn):
    turn(internal=True, tainted=True, actor="")
    assert run("slack_send_dm", {"user_id": OWNER, "text": "FYI"})["sent"] is True
    assert posts(slack)[-1]["channel"] == "D" + OWNER[1:]


def test_a_cron_turn_sends_to_the_owner_with_no_card(slack, turn, legacy_cards):
    turn(cron=True, actor="")
    assert run("slack_send_dm", {"user_id": OWNER, "text": "Daily summary"})["sent"] is True
    assert rows(ItemKind.SEND) == [] and legacy_cards == []


def test_the_report_alias_is_always_sent_now_and_cannot_wait(slack, turn):
    turn(internal=True, tainted=True, actor="")
    assert run("slack_post_message", {"channel": "report", "text": "Done"})["sent"] is True
    assert posts(slack)[-1]["channel"] == "D0REPORT"
    refused = run("slack_post_message", {"channel": "report", "text": "Done?", "wait_for_reply": True})
    assert refused["code"] == "use_this_chat"
    assert len(posts(slack)) == 1


def test_waiting_on_the_owner_is_refused_and_nothing_is_posted(slack, turn):
    turn(named=(OWNER,))
    assert run("slack_send_dm", {"user_id": OWNER, "text": "Ready?", "wait_for_reply": True})["code"] == "use_this_chat"
    assert posts(slack) == [] and rows(ItemKind.ASK) == []


def test_a_waiting_ask_is_reserved_posted_once_and_anchored_on_the_posted_message(slack, turn):
    turn(named=(ALICE,))
    result = run("slack_send_dm", {"user_id": ALICE, "text": "When?", "wait_for_reply": True, "wait_minutes": 90})
    assert result["waiting"]["ask_id"] and len(posts(slack)) == 1
    (item,) = rows(ItemKind.ASK)
    assert item.state is OPEN and item.payload.anchor_ts == result["ts"] and item.payload.target.direct
    assert 89 * 60 < item.expires_at - item.created_at <= 90 * 60


def test_the_same_tool_call_repeated_does_not_post_a_second_time(slack, turn):
    turn(named=(ALICE,))
    args = {"user_id": ALICE, "text": "When?", "wait_for_reply": True}
    first, second = run("slack_send_dm", args), run("slack_send_dm", args)
    assert first["waiting"]["ask_id"] == second["waiting"]["ask_id"]
    assert len(posts(slack)) == 1 and len(rows(ItemKind.ASK)) == 1


def test_an_ask_that_may_have_been_posted_is_not_posted_again_and_says_so(slack, turn):
    turn(named=(ALICE,))
    desk = Desk.in_turn()
    from gateway.desk import Recipient
    from gateway.desk.owner import owner_contact
    from tools.slack_outbound import call_item_id
    reservation = desk.begin_ask(item_id=call_item_id(), origin=desk.origin_of_turn(),
                                 contact=owner_contact("slack", TEAM),
                                 target=Recipient("slack", TEAM, ALICE, "D0ALICE", None, True), question="When?",
                                 wait_minutes=30)
    assert reservation.fresh and reservation.item.state is ItemState.POSTING
    result = run("slack_send_dm", {"user_id": ALICE, "text": "When?", "wait_for_reply": True})
    assert result["code"] == "ask_unconfirmed" and posts(slack) == []


def test_slack_refusing_the_ask_marks_it_failed(slack, turn):
    turn(named=(ALICE,))
    slack.refuse.append("channel_not_found")
    assert "error" in run("slack_send_dm", {"user_id": ALICE, "text": "When?", "wait_for_reply": True})
    (item,) = rows(ItemKind.ASK)
    assert item.state is ItemState.FAILED


def test_a_dropped_connection_leaves_the_ask_unconfirmed_and_a_retry_does_not_post_again(slack, turn):
    turn(named=(ALICE,))
    slack.refuse.append("network_failure")
    args = {"user_id": ALICE, "text": "When?", "wait_for_reply": True}
    assert "error" in run("slack_send_dm", args)
    (item,) = rows(ItemKind.ASK)
    assert item.state is ItemState.POSTING
    assert run("slack_send_dm", args)["code"] == "ask_unconfirmed"
    assert len(posts(slack)) == 1, "only the attempt that dropped; the retry never reached Slack"


def test_pal_and_other_platforms_keep_one_card_per_send_and_never_touch_the_desk(slack, turn, legacy_cards):
    turn(platform="telegram")
    result = run("slack_send_dm", {"user_id": ALICE, "text": "Hello"})
    assert result["sent"] is True and [p["text"] for p in posts(slack)] == ["Hello"]
    assert len(legacy_cards) == 1 and rows(ItemKind.SEND) == [] and rows(ItemKind.ASK) == []


def test_waiting_off_slack_is_declined_in_the_result_and_still_sends_with_the_legacy_card(slack, turn, legacy_cards):
    turn(platform="telegram")
    result = run("slack_send_dm", {"user_id": ALICE, "text": "Hello", "wait_for_reply": True})
    assert result["sent"] is True and result["waiting"] is False
    assert rows(ItemKind.ASK) == []
