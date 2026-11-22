"""slack_react (tools/slack_tools.py) against a fake Slack.

Invariants: an owner turn reacts on any message the bot can see, defaulting to the message that started the turn;
a member turn or a turn made of someone else's words reacts only inside its own conversation and a refused target
reaches no Slack method; a reaction already in the wanted state is success; Slack's own refusals become product
messages.
"""

import json
from urllib.parse import parse_qs

import httpx
import pytest

from gateway.audience import Audience
from gateway.chat_slack.api import SlackApi
from gateway.config import Platform
from gateway.platforms.event import MessageEvent
from gateway.session import SessionSource, build_session_key
from gateway.session_context import clear_session_vars, set_session_vars
from tools import approval, slack_tools
from tools.tainted_turn_gate import admit_tainted_call

TOKEN = "fake-token-do-not-use"
INSTALL = slack_tools.SlackInstall("T0TEAM", "Acme", "vault-item-1")
OWNER = "U0OWNER"
HOME = "C0HOME"
THREAD = "100.000100"
TRIGGER = "100.000200"
IN_THREAD = "100.000300"
ELSEWHERE = "C0ELSEWHERE"
OTHER_THREAD_MESSAGE = "55.000500"


class FakeSlack:
    def __init__(self):
        self.calls: list[tuple[str, dict]] = []
        self.errors: dict[str, str] = {}

    def handle(self, request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        data = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        self.calls.append((method, data))
        if method in self.errors:
            return httpx.Response(200, json={"ok": False, "error": self.errors[method]})
        if method == "conversations.replies":
            replies = {IN_THREAD: {"ts": IN_THREAD, "thread_ts": THREAD}}
            found = replies.get(data["latest"])
            return httpx.Response(200, json={"ok": True, "messages": [{"ts": THREAD, "thread_ts": THREAD}]
                                             + ([found] if found else [])})
        return httpx.Response(200, json={"ok": True})

    def reactions(self) -> list[tuple[str, dict]]:
        return [(m, d) for m, d in self.calls if m.startswith("reactions.")]


@pytest.fixture
def slack(monkeypatch):
    fake = FakeSlack()
    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: INSTALL)
    monkeypatch.setattr(slack_tools, "_bot_token", lambda install: TOKEN)
    monkeypatch.setattr(slack_tools, "_api", lambda: SlackApi(httpx.MockTransport(fake.handle), sleep=lambda s: None))
    return fake


@pytest.fixture
def turn():
    tokens: list = []

    def enter(audience=Audience.OWNER, *, tainted=False, message_id=TRIGGER, thread_id=THREAD, event=True):
        source = SessionSource(platform=Platform.SLACK, chat_id=HOME, chat_type="group", user_id=OWNER,
                               scope_id="T0TEAM", thread_id=thread_id, message_id=message_id, audience=audience)
        turn_event = MessageEvent(text="react heart", source=source, message_id=message_id,
                                  internal=tainted, carries_member_content=tainted) if event else None
        tokens.append(set_session_vars(platform="slack", chat_id=HOME, chat_type="group", scope_id="T0TEAM",
                                       thread_id=thread_id or "", session_key=build_session_key(source),
                                       actor_id=OWNER, turn_event=turn_event))

    yield enter
    for token in tokens:
        clear_session_vars(token)


def react(args: dict) -> dict:
    handler = slack_tools._TOOLS[slack_tools.REACT_TOOL][0]
    return json.loads(slack_tools.run_slack_tool(slack_tools.REACT_TOOL, handler, args))


def test_owner_reacts_on_a_message_in_another_channel(slack, turn):
    turn()
    result = react({"emoji": "tada", "channel": ELSEWHERE, "message_ts": "7.000001"})
    assert slack.reactions() == [("reactions.add", {"channel": ELSEWHERE, "timestamp": "7.000001", "name": "tada"})]
    assert result["emoji"] == "tada" and result["removed"] is False


def test_default_target_is_the_message_that_started_the_turn(slack, turn):
    turn()
    react({"emoji": "heart"})
    assert slack.reactions() == [("reactions.add", {"channel": HOME, "timestamp": TRIGGER, "name": "heart"})]


def test_a_follow_up_turn_reacts_on_its_own_message_not_the_first_one(slack, turn):
    turn(message_id="100.000999")
    react({"emoji": "heart"})
    assert slack.reactions()[0][1]["timestamp"] == "100.000999"


@pytest.mark.parametrize("raw, name", [(":heart:", "heart"), (" Heart ", "heart"), ("+1", "+1"),
                                       ("thumbsup::skin-tone-3", "thumbsup::skin-tone-3")])
def test_emoji_names_are_normalized(slack, turn, raw, name):
    turn()
    react({"emoji": raw})
    assert slack.reactions()[0][1]["name"] == name


@pytest.mark.parametrize("emoji, code", [("❤️", "emoji_unsupported"), ("", "emoji_invalid"),
                                         ("::", "emoji_invalid"), ("not an emoji", "emoji_invalid")])
def test_a_bad_emoji_is_refused_before_any_slack_call(slack, turn, emoji, code):
    turn()
    assert react({"emoji": emoji})["code"] == code
    assert slack.calls == []


@pytest.mark.parametrize("target", [{"channel": ELSEWHERE}, {"message_ts": "7.000001"},
                                    {"channel": "general", "message_ts": "7.000001"},
                                    {"channel": ELSEWHERE, "message_ts": "yesterday"}])
def test_a_half_or_malformed_target_is_refused_before_any_slack_call(slack, turn, target):
    turn()
    assert react({"emoji": "heart", **target})["code"].startswith("react_target_")
    assert slack.calls == []


def test_a_turn_with_no_triggering_message_never_guesses_one(slack, turn):
    turn(event=False)
    assert react({"emoji": "heart"})["code"] == "react_target_missing"
    assert slack.calls == []


def test_remove_takes_the_reaction_off(slack, turn):
    turn()
    result = react({"emoji": "heart", "remove": True})
    assert slack.reactions() == [("reactions.remove", {"channel": HOME, "timestamp": TRIGGER, "name": "heart"})]
    assert result["removed"] is True


def test_reacting_twice_and_removing_what_is_not_there_both_succeed(slack, turn):
    turn()
    slack.errors["reactions.add"] = "already_reacted"
    assert react({"emoji": "heart"})["emoji"] == "heart"
    slack.errors = {"reactions.remove": "no_reaction"}
    assert react({"emoji": "heart", "remove": True})["removed"] is True


@pytest.mark.parametrize("slack_error, code", [("missing_scope", "slack_missing_scope"),
                                               ("message_not_found", "slack_message_not_found"),
                                               ("invalid_name", "slack_unknown_emoji"),
                                               ("not_in_channel", "slack_not_in_channel")])
def test_slack_refusals_become_product_messages(slack, turn, slack_error, code):
    turn()
    slack.errors["reactions.add"] = slack_error
    body = react({"emoji": "heart"})
    assert body["code"] == code and "reactions" not in body["error"]


def test_member_turn_reacts_on_the_message_it_is_answering(slack, turn):
    turn(Audience.MEMBER)
    react({"emoji": "heart"})
    assert slack.reactions() == [("reactions.add", {"channel": HOME, "timestamp": TRIGGER, "name": "heart"})]


@pytest.mark.parametrize("target", [{"channel": ELSEWHERE, "message_ts": "7.000001"},
                                    {"channel": HOME, "message_ts": OTHER_THREAD_MESSAGE}])
@pytest.mark.parametrize("lane", [dict(audience=Audience.MEMBER), dict(tainted=True)])
def test_a_restricted_turn_cannot_react_outside_its_conversation(slack, turn, lane, target):
    turn(**lane)
    assert react({"emoji": "heart", **target})["code"] == "slack_member_scope"
    assert slack.reactions() == []


@pytest.mark.parametrize("lane", [dict(audience=Audience.MEMBER), dict(tainted=True)])
@pytest.mark.parametrize("message_ts", [THREAD, IN_THREAD])
def test_a_restricted_turn_reacts_inside_its_own_thread(slack, turn, lane, message_ts):
    turn(**lane)
    react({"emoji": "heart", "channel": HOME, "message_ts": message_ts})
    assert [d["timestamp"] for _, d in slack.reactions()] == [message_ts]


def test_a_restricted_turn_without_a_thread_reacts_anywhere_in_its_channel(slack, turn):
    turn(Audience.MEMBER, thread_id=None)
    react({"emoji": "heart", "channel": HOME, "message_ts": OTHER_THREAD_MESSAGE})
    assert slack.reactions()[0][1]["timestamp"] == OTHER_THREAD_MESSAGE
    assert "conversations.replies" not in [m for m, _ in slack.calls]


def test_a_turn_made_of_someone_elses_words_reacts_in_its_conversation_without_an_owner_card(slack, turn, monkeypatch):
    cards: list = []
    monkeypatch.setattr(approval, "request_draft_approval", lambda **card: cards.append(card) or {"approved": False})
    monkeypatch.setenv("SLACK_ALLOWED_USERS", OWNER)
    monkeypatch.setenv("SLACK_HOME_CHANNEL", "D0OWNER")
    turn(tainted=True)
    assert admit_tainted_call(slack_tools.REACT_TOOL, {"emoji": "heart"}) == (None, None)
    assert admit_tainted_call("slack_post_message", {"channel": HOME, "text": "x"})[0] is not None
    react({"emoji": "heart"})
    assert slack.reactions()[0][1]["timestamp"] == TRIGGER
    assert len(cards) == 1
