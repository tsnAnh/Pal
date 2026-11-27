"""What the owner types in this turn can be the approval for one send, and a standing order saves a rule."""

import asyncio
import contextvars
import json
import logging
import threading
from types import SimpleNamespace

import pytest

from agent.delegation_context import delegated_child_context
from gateway.run_plugin_injection import person_input_joined_turn
from gateway.session_authority import SessionAuthority
from gateway.session_operator import typed_words
from tests.tools import test_bot_mode_drafts as drafts
from tests.tools import test_mcp_action_gate as mcp
from tests.tools.test_send_rules import (
    ARGS, ASK_EVERYTHING, MCP_ARGS, MCP_SEND, OFFERED, PLAIN, POST, REVENUE, _action, _fresh_turn, _logged, _send,
)
from tools import mcp_action_gate, send_rules
from tools.bot_mode_drafts import classify_outbound, review_outbound
from tools.clarify_tool import clarify_tool
from tools.details_bubble import bound_line_sink
from tools.send_rules import turn_order
from tools.send_rules.order_text import read_order

bot_home = drafts.bot_home
Owner = mcp.Owner

NAMED = "#app-revenue-notifications"


@pytest.fixture(autouse=True)
def _info_logs(caplog):
    caplog.set_level(logging.INFO)


@pytest.fixture
def lines():
    posted = []
    with bound_line_sink(lambda text: posted.append(text) or True):
        yield posted


ORDERS = {
    "send it": (False, ()),
    "Send it.": (False, ()),
    "ok send it, thanks": (False, ()),
    "yes go ahead and post it": (False, ()),
    "you can send it": (False, ()),
    "no need to ask, just send it": (False, ()),
    "gửi đi": (False, ()),
    "ừ gửi luôn nhé": (False, ()),
    "cứ gửi đi bạn": (False, ()),
    "không cần hỏi, gửi đi": (False, ()),
    "stop asking": (True, ()),
    "Stop asking me, send it": (True, ()),
    "Don’t ask me again, just send it": (True, ()),
    "send freely": (True, ()),
    "you can send there, stop asking": (True, ()),
    "always send it there": (True, ()),
    "từ giờ cứ gửi": (True, ()),
    "từ giờ cứ gửi, đừng hỏi nữa": (True, ()),
    "cứ gửi thoải mái": (True, ()),
    "đừng hỏi nữa": (True, ()),
    f"post it to {NAMED}": (False, (NAMED,)),
    f"post it to slack:{NAMED} please": (False, (f"slack:{NAMED}",)),
    "send it to ada@example.com": (False, ("ada@example.com",)),
    "send it to app-revenue-notifications": (False, ("app-revenue-notifications",)),
    f"from now on send it to {NAMED}": (True, (NAMED,)),
    f"send the weekly revenue report to {NAMED}": (False, (NAMED,)),
    f"please send today's numbers to channel {NAMED}": (False, (NAMED,)),
    f"always send the daily numbers to {NAMED}": (True, (NAMED,)),
    f"gửi báo cáo doanh thu vào kênh {NAMED} đi": (False, (NAMED,)),
    f"gửi vào {NAMED}, từ giờ cứ gửi": (True, (NAMED,)),
}


@pytest.mark.parametrize("text,expected", ORDERS.items(), ids=list(ORDERS))
def test_an_order_is_read_from_the_owner_words(text, expected):
    order = read_order(text)
    assert order is not None and (order.standing, order.places) == expected


NOT_ORDERS = [
    "", "ok", "yes", "được", "ừ", "thanks", "go ahead",
    "send it?", "should I send it", "can you send it?", "gửi đi được không", "gửi chưa",
    "don't send it", "do not post it", "never send it", "stop sending", "đừng gửi", "đừng gửi đi", "chưa gửi đâu",
    "không gửi đi", "khoan, đừng gửi vội", "thôi đừng gửi", "đừng hỏi nữa, đừng gửi",
    "if it looks good send it", "send it after the review", "send it tomorrow", "nếu đúng thì gửi đi",
    "send it to me", "gửi cho tôi", "gửi đi cho khách", "send me the report", "send it to finance",
    "stop asking me questions", "đừng hỏi nữa, tôi bận", "ok send it but fix the typo first",
    f"what did you send to {NAMED}", f"send nothing to {NAMED}", f"send the report to {NAMED} tomorrow",
    f"send the summary of {NAMED} to ada@example.com", f"don't send the report to {NAMED}",
    f"gửi tóm tắt của kênh {NAMED} sang ada@example.com", f"the report went to {NAMED}",
    f"send fewer messages to {NAMED}", f"gửi nhầm vào {NAMED}", f"stop sending to {NAMED}", "from now on",
    "please don't ask", "just don't ask", "khỏi hỏi", "no need to ask", "lần sau gửi nhé", "lần sau cứ gửi",
    "lần sau đừng hỏi", "được gửi đi", "đăng nhập vào bob@example.com", "đăng ký nhận tin vào bob@example.com",
    "post mortem notes go to #general", "send button jumps to #general",
    "send it to finance rather than to #general", "send it to the team except to #general",
    "send it to finance, skip posting to #general", "send zero messages to #general",
    "send nobody anything to #general", "send neither one to #general", "send nada to #general",
    "gửi chả có gì vào #general", "gửi chẳng cái gì vào #general", "gửi báo cáo cấm vào #general",
    "send it assuming i approve to #general", "send it as soon as i confirm to #general",
    "send it on approval to #general", "gửi báo cáo miễn là đúng vào #general", "gửi báo cáo giả sử đúng vào #general",
    "gửi báo cáo kẻo trễ vào #general", "send it friday to #general", "send it next week to #general",
    "send it in an hour to #general", "send it tonight to #general", "gửi báo cáo tối nay vào #general",
    "gửi báo cáo thứ sáu vào #general", "gửi báo cáo tuần tới vào #general",
    "send the invoice. complain to ada@example.com", "send boss the file, i'll talk to ada@example.com",
    'he said "send it"', "> send it\nwhat does this mean", "`send it`", "'send it'",
    "send it " * 40,
]


@pytest.mark.parametrize("text", NOT_ORDERS)
def test_anything_else_is_not_an_order(text):
    assert read_order(text) is None


def _turn(words):
    return turn_order.opened(SimpleNamespace(send_order=None), words)


def test_an_order_covers_one_send_in_its_turn_and_saves_nothing(bot_home, lines, caplog):
    with _turn("send it"):
        sent = _send()
        again = _send({**ARGS, "text": "second"})
    assert (sent.block, sent.cards) == (None, [])
    assert len(again.cards) == 1 and again.cards[0]["choices"] == OFFERED
    assert send_rules.list_rules() == [] and lines == []
    assert _logged(caplog, "send allowed by owner order") == [
        f"send allowed by owner order bot=default destination={REVENUE}"]
    assert len(_send().cards) == 1


@pytest.mark.parametrize("words", [None, "ok", "should I send it?"])
def test_a_turn_without_an_order_asks_and_offers_always(bot_home, words):
    with _turn(words):
        asked = _send()
    assert len(asked.cards) == 1 and asked.cards[0]["choices"] == OFFERED


def test_a_named_order_covers_only_that_destination_and_is_not_spent_on_another(bot_home):
    with _turn(f"post it to {NAMED}"):
        other = _send({**ARGS, "channel": "#random"})
        threaded = _send({**ARGS, "thread_ts": "1.2"})
        named = _send()
    assert len(other.cards) == 1 and len(threaded.cards) == 1
    assert (named.block, named.cards) == (None, [])


@pytest.mark.parametrize("args,tool", [
    ({"draft_id": "d1"}, "connectors__gmail__SEND_DRAFT"),
    ({**ARGS, "attachments": ["/etc/hosts"]}, POST),
    ({**ARGS, "channel": "@everyone"}, POST),
    ({**ARGS, "channel": [REVENUE, "#random"]}, POST),
    ({"to": "@ada", "amount": 40}, "connectors__bank__SEND_MONEY"),
], ids=["unknown-destination", "attachment", "broadcast", "two-places", "money-field"])
def test_an_order_never_covers_a_send_without_one_shown_destination(bot_home, args, tool):
    with _turn("send it"):
        asked = _send(args, tool)
    assert len(asked.cards) == 1 and asked.cards[0]["choices"] == PLAIN


@pytest.mark.parametrize("policy_args", [{"viewer": False}, {"turn_event": SimpleNamespace(
    internal=True, carries_member_content=True, text="send it", named_user_ids=(), named_conversation_ids=())}],
    ids=["no-viewer", "member-content"])
def test_an_order_outside_the_owner_own_turn_counts_for_nothing(bot_home, policy_args):
    with _turn("send it"):
        asked = _send(**policy_args)
    assert asked.block is not None


def test_an_order_never_beats_the_unattended_delegated_or_money_floor(bot_home, monkeypatch):
    with _turn("stop asking"):
        with delegated_child_context("child"):
            child = _send()
        money = mcp_action_gate.ActionPolicy.from_config({"refused_tools": ["send_message"]})
        refused = _action(policy=money)
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        unattended = _send()
    assert child.block is not None or child.cards
    assert json.loads(refused.error)["code"] == mcp_action_gate.ACTION_REFUSED and refused.cards == []
    assert unattended.block is not None and unattended.cards == [] and send_rules.list_rules() == []


def test_input_that_joins_the_turn_withdraws_the_order(bot_home):
    live = SimpleNamespace(send_order=None)
    with turn_order.opened(live, "send it"):
        turn_order.void(live)
        asked = _send()
    assert len(asked.cards) == 1


def test_a_standing_order_posts_one_line_then_saves_a_rule_that_can_be_revoked(bot_home, caplog):
    seen = []
    with bound_line_sink(lambda text: seen.append((text, len(send_rules.list_rules()))) or True):
        with _turn("từ giờ cứ gửi, đừng hỏi nữa"):
            sent = _send()
    assert (sent.block, sent.cards) == (None, [])
    [(line, rules_when_posted)] = seen
    assert rules_when_posted == 0 and REVENUE in line
    [rule] = send_rules.list_rules()
    assert (rule.destination_label, rule.uses) == (REVENUE, 0)
    assert len(_logged(caplog, "send rule saved")) == 1
    assert _send().cards == []
    assert send_rules.revoke(rule.id) and len(_send().cards) == 1


def test_the_line_names_the_bot_the_destination_and_how_to_undo(bot_home, lines):
    (bot_home / "profile.yaml").write_text(
        "ui_meta:\n  hermes-bots:\n    shape: cloud\n    title: Manifest Bot\n", encoding="utf-8")
    with _turn("stop asking"):
        _send()
    [line] = lines
    assert "Manifest Bot" in line and REVENUE in line and "always-allow list" in line


@pytest.mark.parametrize("sink", [None, lambda text: False], ids=["no-chat-line", "line-refused"])
def test_a_standing_order_saves_no_rule_when_no_line_can_be_posted(bot_home, sink):
    with bound_line_sink(sink), _turn("stop asking"):
        sent = _send()
    assert (sent.block, sent.cards) == (None, []) and send_rules.list_rules() == []


@pytest.mark.parametrize("words,saved", [("send it", 0), ("stop asking", 1)])
def test_an_ordered_send_through_both_gates_never_asks(bot_home, lines, words, saved):
    with Owner() as chat, _turn(words):
        _fresh_turn()
        assert review_outbound(MCP_SEND, dict(MCP_ARGS)) == (None, None)
        error, grant = mcp_action_gate.gate(ASK_EVERYTHING, "telegram", "send_message", dict(MCP_ARGS))
    assert error is None and grant is not None and chat.cards == []
    assert len(send_rules.list_rules()) == saved == len(lines)
    assert [rule.uses for rule in send_rules.list_rules()] == [0] * saved
    assert len(_action().cards) == (0 if saved else 1)


def test_the_action_gate_alone_spends_the_order_once(bot_home, lines):
    with _turn("send it"):
        first = _action()
        second = _action({**MCP_ARGS, "message": "again"})
    assert first.error is None and first.cards == [] and len(second.cards) == 1


def _ask(send=True, choices=("Send", "Cancel"), extra=()):
    shown = []

    def callback(questions):
        shown.append(questions)
        return {"answers": {}, "outcome": "cancelled"}

    question = {"question": "Send to the revenue channel?", "choices": list(choices)}
    if send:
        question["send"] = {"tool": POST, "arguments": dict(ARGS), "choice": "Send"}
    with Owner():
        _fresh_turn()
        result = json.loads(clarify_tool([question, *extra], callback=callback))
    return result, shown


@pytest.mark.parametrize("words", ["send it", f"send it to {NAMED}"])
def test_no_form_is_shown_for_a_send_the_owner_already_ordered(bot_home, words):
    with _turn(words):
        result, shown = _ask()
        assert shown == [] and result["outcome"] == "not_asked" and "send" in result["notice"].lower()
        assert _send().cards == []


def test_no_form_is_shown_for_a_send_a_saved_rule_covers(bot_home, lines):
    with _turn("stop asking"):
        _send()
    result, shown = _ask()
    assert shown == [] and result["outcome"] == "not_asked"


@pytest.mark.parametrize("words,kwargs", [
    (None, {}), ("ok", {}), ("send it to #somewhere-else", {}), ("send it", {"send": False}),
    ("send it", {"extra": ({"question": "Which week?", "default": "this one"},)}),
], ids=["no-order", "bare-ok", "other-destination", "plain-question", "another-question"])
def test_a_form_is_still_shown_otherwise(bot_home, words, kwargs):
    with _turn(words):
        _result, shown = _ask(**kwargs)
    assert len(shown) == 1


def test_a_bare_order_belongs_to_the_first_send_even_when_a_rule_cleared_it(bot_home, lines):
    with _turn("stop asking"):
        _send()
    with _turn("send it"):
        assert _send().cards == []
        assert len(_send({**ARGS, "channel": "#random"}).cards) == 1


def test_a_bare_order_is_gone_after_a_first_send_that_needed_a_card(bot_home):
    with _turn("send it"):
        _send({"draft_id": "d1"}, "connectors__gmail__SEND_DRAFT")
        assert len(_send().cards) == 1


def test_an_order_does_not_outlive_its_turn_in_a_copied_context(bot_home):
    with _turn("send it"):
        kept = contextvars.copy_context()
    assert len(kept.run(_send).cards) == 1


def test_the_pass_between_the_gates_covers_that_exact_call_only(bot_home):
    with Owner(choice="deny") as chat, _turn("send it"):
        _fresh_turn()
        assert review_outbound(MCP_SEND, dict(MCP_ARGS)) == (None, None)
        error, _grant = mcp_action_gate.gate(
            ASK_EVERYTHING, "telegram", "send_message", {**MCP_ARGS, "message": "something else"})
    assert error is not None and len(chat.cards) == 1


@pytest.mark.parametrize("words,answer", [("stop asking", "deny"), (None, "always")], ids=["order", "card"])
def test_a_rule_the_draft_card_could_name_is_honoured_by_the_action_gate(bot_home, lines, words, answer):
    args = {"channel_id": "C0APPREV12", "message": "hi"}

    def both(text, choice):
        with Owner(choice=choice) as chat, _turn(text):
            _fresh_turn()
            assert review_outbound(MCP_SEND, dict(args)) == (None, None)
            error, _grant = mcp_action_gate.gate(ASK_EVERYTHING, "telegram", "send_message", dict(args))
        assert error is None
        return chat.cards

    assert len(both(words, answer)) == (1 if answer == "always" else 0)
    assert both(None, "deny") == []


def _live(order_words):
    live = SimpleNamespace(send_order=None, route="chat-a", event_stream=SimpleNamespace(lock=threading.RLock()))
    return live, turn_order.opened(live, order_words)


def test_a_steer_latched_before_the_turn_opened_withdraws_the_order(bot_home):
    live, opened = _live("send it")
    authority = SimpleNamespace(sessions={"s": live}, adopted={}, delivered_stops={}, pending_stops={},
                                pending_steers={"s": (1, ["do not send it"])}, latched_transfers={})
    with opened:
        SessionAuthority.adopt_agent(authority, "s", 1, SimpleNamespace(steer=lambda text: True))
        assert len(_send().cards) == 1


def test_a_chat_message_folded_into_the_turn_withdraws_the_order(bot_home, monkeypatch):
    live, opened = _live("send it")
    authority = SimpleNamespace(sessions={"s": live})
    monkeypatch.setattr("gateway.session_authorities.active_authority", lambda runner: authority)
    with opened:
        person_input_joined_turn(object(), "chat-a")
        assert len(_send().cards) == 1


@pytest.mark.parametrize("kind", ["clarify", "approval"])
def test_an_answer_to_any_prompt_withdraws_the_order(bot_home, kind):
    live, opened = _live("send it")
    actor = object()
    live.subscribers, live.controls = {"app": actor}, SimpleNamespace(respond=lambda *a, **k: {})
    authority = SimpleNamespace(sessions={"s": live}, authorize=lambda *a: None,
                                check_approval_generation=lambda *a: None)
    with opened:
        asyncio.run(SessionAuthority.respond(authority, actor, SimpleNamespace(session_id="s"), 1, "p", {}, kind=kind))
        assert len(_send().cards) == 1


@pytest.mark.parametrize("choices", [["Send raw", "Fix first", "Don't send"], ["Send", "Send to #random instead"]])
def test_a_form_with_a_real_choice_is_still_shown(bot_home, choices):
    question = {"question": "Revenue reads 0. Which version?", "choices": choices,
                "send": {"tool": POST, "arguments": dict(ARGS), "choice": choices[0]}}
    shown = []
    with Owner(), _turn("send it"):
        clarify_tool([question], callback=lambda q: shown.append(q) or {"answers": {}, "outcome": "cancelled"})
    assert len(shown) == 1


def _row(**payload):
    return {"request_id": "r1", "payload": {"text": "send it", **payload}}


def test_only_a_plain_message_a_viewer_typed_can_carry_an_order():
    assert typed_words(_row()) == "send it" == typed_words(_row(surface_v1={}, attachments_v1=[]))
    for extra in ({"display_v1": {"kind": "hidden"}}, {"cli_turn_v1": {}}, {"kanban_card_v1": {}},
                  {"unattended": True}, {"finite": True}, {"local_automation_v1": {}}, {"native_text_v1": {}}):
        assert typed_words(_row(**extra)) is None, extra
    assert typed_words({**_row(), "request_id": "hosted:1"}) is None
    assert typed_words(_row(surface_v1={"surface": "voice-live"})) is None
    assert typed_words(_row(surface_v1={"voice_turn": True})) is None


CHANNEL_SPELLINGS = ["app-revenue-notifications", NAMED, f"slack:{NAMED}", "slack:app-revenue-notifications"]


@pytest.mark.parametrize("listed", CHANNEL_SPELLINGS)
@pytest.mark.parametrize("called", CHANNEL_SPELLINGS)
def test_a_listed_slack_channel_matches_with_or_without_prefix_and_hash(bot_home, monkeypatch, listed, called):
    monkeypatch.setattr("hermes_cli.config.load_config_readonly",
                        lambda: {"bot_mode": {"owner_recipients": [listed]}})
    tool, args = (("send_message", {"target": called, "message": "hi"}) if called.startswith("slack:")
                  else (POST, {"channel": called, "text": "hi"}))
    assert _class_of(tool, args) == "own_agent"


def _class_of(tool, args):
    from tools.bot_mode_drafts import recipient_class
    return recipient_class(classify_outbound(tool, args))


@pytest.mark.parametrize("listed,tool,args", [
    (NAMED, POST, {"channel": "#app-revenue", "text": "hi"}),
    (NAMED, POST, {"channel": "@app-revenue-notifications", "text": "hi"}),
    (NAMED, "connectors__discord__SEND_MESSAGE", {"channel": "app-revenue-notifications", "content": "hi"}),
    (NAMED, "send_message", {"target": "telegram:app-revenue-notifications", "message": "hi"}),
    ("slack:C0APPREV12", "send_message", {"target": "slack:C0APPREV12:171.2", "message": "hi"}),
    ("#", POST, {"channel": "slack:", "text": "hi"}),
], ids=["other-name", "a-user", "other-platform", "other-prefix", "a-thread", "empty"])
def test_a_listed_channel_matches_nothing_else(bot_home, monkeypatch, listed, tool, args):
    monkeypatch.setattr("hermes_cli.config.load_config_readonly",
                        lambda: {"bot_mode": {"owner_recipients": [listed]}})
    assert _class_of(tool, args) == "person"


SEND_MESSAGE_FORMS = {
    f"slack:{NAMED}": None,
    "slack:C0APPREV12": '{"address":{"target":"slack:C0APPREV12"},"identity":{}}',
    "slack:C0APPREV12:1712345678.000100":
        '{"address":{"target":"slack:C0APPREV12:1712345678.000100"},"identity":{}}',
}


@pytest.mark.parametrize("target,signature", SEND_MESSAGE_FORMS.items(), ids=list(SEND_MESSAGE_FORMS))
def test_send_message_slack_targets_keep_the_raw_recipient_and_key_rules_on_native_ids(bot_home, target, signature):
    args = {"target": target, "message": "hi"}
    assert classify_outbound("send_message", args).recipient == target
    destination = send_rules.destination_of("send_message", args)
    assert (destination and destination.signature) == signature


def test_a_message_carrying_a_credential_is_never_covered(bot_home):
    secret = {"to": "@ada", "message": "key sk-proj-" + "a1B2c3D4" * 6}
    assert send_rules.destination_of(MCP_SEND, secret) is None
    assert send_rules.destination_of(MCP_SEND, MCP_ARGS) is not None
