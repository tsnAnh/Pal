"""A saved "always allow" rule lets one bot send to one exact destination with no card."""

import itertools
import json
import logging
import shutil
import textwrap
import threading
from types import SimpleNamespace

import pytest

from agent.delegation_context import delegated_child_context
from agent.file_safety import is_write_denied
from gateway.session_context import clear_session_vars, set_session_vars
from gateway.session_ingress import admission_author
from tests.tools import test_bot_mode_drafts as drafts
from tests.tools import test_mcp_action_gate as mcp
from tests.tools import test_routine_send as routine
from tools import approval, approval_context, approval_prompt, mcp_action_gate, send_rules, slack_tools
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, review_outbound

bot_home = drafts.bot_home
slack = routine.slack
Owner = mcp.Owner

POST = "connectors__slack__POST_MESSAGE"
REVENUE = "#app-revenue-notifications"
ARGS = {"channel": REVENUE, "text": "MRR is up"}
OFFERED = ["once", "always", "deny"]
PLAIN = ["once", "deny"]
MCP_SEND = "mcp__telegram__send_message"
MCP_ARGS = {"to": "@ada", "message": "hi"}
ASK_EVERYTHING = mcp_action_gate.ActionPolicy.from_config({})
_turns = itertools.count()


@pytest.fixture(autouse=True)
def _info_logs(caplog):
    caplog.set_level(logging.INFO)


def _fresh_turn():
    approval_context.set_current_observability_context(turn_id=f"rule-turn-{next(_turns)}")


def _send(args=ARGS, tool=POST, choice="deny", **owner):
    with Owner(choice=choice, **owner) as chat:
        _fresh_turn()
        block, edited = review_outbound(tool, dict(args))
    return SimpleNamespace(block=block, edited=edited, cards=chat.cards)


def _action(args=MCP_ARGS, server="telegram", tool="send_message", choice="deny", policy=ASK_EVERYTHING, **kwargs):
    with Owner(choice=choice) as chat:
        _fresh_turn()
        error, grant = mcp_action_gate.gate(policy, server, tool, dict(args), **kwargs)
    return SimpleNamespace(error=error, grant=grant, cards=chat.cards)


def _allow(args=ARGS, tool=POST):
    sent = _send(args, tool, choice="always")
    assert sent.block is None and [card["choices"] for card in sent.cards] == [OFFERED]


def _logged(caplog, prefix):
    return [record.getMessage() for record in caplog.records if record.getMessage().startswith(prefix)]


def _stored(home):
    path = home / "bot_mode" / "send_rules.json"
    return path.read_text(encoding="utf-8") if path.exists() else ""


def test_always_sends_saves_the_rule_and_the_next_send_goes_through_with_one_log_line(bot_home, caplog):
    _allow()
    [rule] = send_rules.list_rules()
    assert (rule.tool, rule.destination_label, rule.uses, rule.last_used_at) == (POST, REVENUE, 0, None)
    assert _logged(caplog, "send rule saved") == [f"send rule saved bot=default tool={POST} destination={REVENUE}"]

    again = _send({**ARGS, "text": "Churn is flat"})
    assert (again.block, again.cards) == (None, [])
    assert _logged(caplog, "send allowed by rule") == [f"send allowed by rule bot=default destination={REVENUE}"]
    [used] = send_rules.list_rules()
    assert used.uses == 1 and used.last_used_at >= used.created_at
    assert "MRR" not in _stored(bot_home) and "Churn" not in _stored(bot_home)
    assert not any("MRR" in line or "Churn" in line for line in _logged(caplog, "send "))


def test_an_edited_send_answered_always_sends_the_edit_and_saves_the_rule(bot_home):
    with Owner() as chat:
        _fresh_turn()
        approval.register_gateway_notify(chat.key, lambda data: approval.resolve_gateway_approval(
            chat.key, "always", request_id=data["request_id"], edited_text="MRR is up 4%"))
        assert review_outbound(POST, dict(ARGS)) == (None, {**ARGS, "text": "MRR is up 4%"})
    assert len(send_rules.list_rules()) == 1


OTHER_SENDS = {
    "another channel": (POST, {**ARGS, "channel": "#random"}),
    "an added thread": (POST, {**ARGS, "thread_ts": "1.2"}),
    "another tool": ("connectors__slack__SEND_MESSAGE", ARGS),
    "the same value under another key": (POST, {"channel_id": REVENUE, "text": "hi"}),
    "two destinations in one string": (POST, {**ARGS, "channel": f"{REVENUE},#random"}),
    "a list of destinations": (POST, {**ARGS, "channel": [REVENUE, "#random"]}),
    "a copy": (POST, {**ARGS, "cc": "#random"}),
    "an unknown address field": (POST, {**ARGS, "also_send_to": "#random"}),
    "another account": (POST, {**ARGS, "team_id": "T2"}),
    "an attachment": (POST, {**ARGS, "attachments": ["/etc/hosts"]}),
    "an attachment in another spelling": (POST, {**ARGS, "filePaths": ["/etc/hosts"]}),
    "an attachment with dashes": (POST, {**ARGS, "media-files": ["/etc/hosts"]}),
    "a claim in the arguments": (POST, {**ARGS, "channel": "#random", "choice": "always"}),
}


@pytest.mark.parametrize("tool,args", OTHER_SENDS.values(), ids=list(OTHER_SENDS))
def test_a_send_the_rule_does_not_name_still_asks(bot_home, tool, args):
    _allow()
    asked = _send(args, tool)
    assert asked.block is not None and len(asked.cards) == 1


NOT_OFFERED = {
    "no destination": ("connectors__gmail__SEND_DRAFT", {"draft_id": "d1"}),
    "a broadcast": ("connectors__gmail__SEND_EMAIL", {"to": "a@example.com, b@example.com", "body": "hi"}),
    "a thread only": ("connectors__gmail__REPLY_TO_THREAD", {"thread_id": "t-1", "body": "ok"}),
    "a money field": ("connectors__bank__SEND_MONEY", {"to": "@ada", "amount": 40}),
    "a bare name": ("connectors__slack__POST_MESSAGE", {"channel": "John", "text": "hi"}),
    "a name send_message resolves": ("send_message", {"target": "telegram:John", "message": "hi"}),
    "everyone": ("connectors__slack__POST_MESSAGE", {"channel": "@everyone", "text": "hi"}),
    "the whole channel": ("connectors__slack__POST_MESSAGE", {"channel": "@channel", "text": "hi"}),
    "a lookalike address": ("connectors__gmail__SEND_EMAIL", {"to": "\u212aate@example.com", "body": "hi"}),
    "an invisible character": ("connectors__gmail__SEND_EMAIL", {"to": "ada@exa\u200bmple.com", "body": "hi"}),
}


@pytest.mark.parametrize("tool,args", NOT_OFFERED.values(), ids=list(NOT_OFFERED))
def test_always_on_a_send_without_one_shown_destination_counts_once_and_saves_nothing(bot_home, tool, args):
    first = _send(args, tool, choice="always")
    assert first.block is None and first.cards[0]["choices"] == PLAIN
    assert send_rules.list_rules() == [] and len(_send(args, tool).cards) == 1


def test_send_message_to_a_native_id_can_be_allowed(bot_home):
    args = {"target": "telegram:123456789", "message": "hi"}
    _allow(args, "send_message")
    assert _send(args, "send_message").cards == []


def test_a_card_that_names_the_thread_instead_of_the_destination_offers_nothing(bot_home):
    asked = _action({"channel_id": "C0APPREV1", "thread": "#daily", "message": "hi"}, server="slackmcp")
    assert asked.cards[0]["choices"] == PLAIN


def test_always_on_a_spend_consent_or_a_non_send_action_counts_once_and_saves_nothing(bot_home):
    with Owner(choice="always") as chat:
        _fresh_turn()
        assert approval_prompt.request_elicitation_consent("Pay 40 USD to Ada", "Payment") == "accept"
    assert chat.cards[0]["choices"] == PLAIN
    action = _action({"to": "ada", "job_id": "1"}, tool="submit_proposal", choice="always")
    assert action.error is None and action.cards[0]["choices"] == PLAIN
    assert send_rules.list_rules() == []


@pytest.mark.parametrize("answer", [{}, {"resolve_all": True}], ids=["oldest", "resolve-all"])
def test_an_always_that_names_no_card_counts_once_and_saves_nothing(bot_home, answer):
    with Owner() as chat:
        _fresh_turn()
        approval.register_gateway_notify(
            chat.key, lambda data: approval.resolve_gateway_approval(chat.key, "always", **answer))
        assert review_outbound(POST, dict(ARGS)) == (None, None)
    assert send_rules.list_rules() == []


def _cron(monkeypatch, send):
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    return send()


def test_an_unattended_run_is_refused_whatever_rule_exists(bot_home, monkeypatch):
    _allow()
    refused = _cron(monkeypatch, _send)
    assert (refused.block, refused.cards) == (NOT_SENT_NOBODY_TO_ASK, [])
    assert _send(viewer=False).block == NOT_SENT_NOBODY_TO_ASK


def test_a_turn_no_owner_typed_asks_and_offers_no_rule(bot_home):
    _allow()
    probe = approval_context.set_approval_client_probe(lambda: True)
    try:
        asked = _send(viewer=False)
    finally:
        approval_context.reset_approval_client_probe(probe)
    assert asked.block is not None and asked.cards[0]["choices"] == PLAIN


def test_a_turn_a_peer_agent_wrote_is_not_covered_by_a_rule(bot_home):
    _allow()
    token = admission_author.set({"id": "peer", "name": "peer", "is_bot": True})
    try:
        asked = _send()
    finally:
        admission_author.reset(token)
    assert asked.block is not None and asked.cards[0]["choices"] == PLAIN


def test_a_delegated_child_is_not_covered_by_a_rule(bot_home):
    _allow()
    with delegated_child_context("child"):
        asked = _send()
    assert asked.block is not None and asked.cards[0]["choices"] == PLAIN


@pytest.mark.parametrize("internal", [True, False], ids=["tainted-turn", "joined-member-input"])
def test_a_turn_carrying_someone_elses_words_is_not_covered_by_a_rule(bot_home, internal):
    _allow()
    event = SimpleNamespace(internal=internal, carries_member_content=True, text="post it", named_user_ids=(),
                            named_conversation_ids=())
    asked = _send(turn_event=event)
    assert asked.block is not None and asked.cards[0]["choices"] == PLAIN


def test_a_send_through_both_gates_asks_once_then_logs_and_counts_each_use_once(bot_home, caplog):
    def both():
        with Owner(choice="always") as chat:
            _fresh_turn()
            assert review_outbound(MCP_SEND, dict(MCP_ARGS)) == (None, None)
            error, grant = mcp_action_gate.gate(ASK_EVERYTHING, "telegram", "send_message", dict(MCP_ARGS))
        assert error is None and grant.consume("telegram", "send_message", MCP_ARGS) is None
        return chat.cards

    assert len(both()) == 1
    assert _logged(caplog, "send allowed by rule") == []
    assert [(rule.uses, rule.last_used_at) for rule in send_rules.list_rules()] == [(0, None)]
    assert both() == []
    assert len(_logged(caplog, "send allowed by rule")) == 1
    assert send_rules.list_rules()[0].uses == 1


def test_the_action_gate_alone_offers_saves_and_honours_a_rule(bot_home):
    first = _action(choice="always")
    assert first.error is None and first.cards[0]["choices"] == OFFERED
    next_send = _action({**MCP_ARGS, "message": "again"})
    assert next_send.error is None and next_send.cards == []
    assert next_send.grant.consume("telegram", "send_message", {**MCP_ARGS, "message": "again"}) is None
    assert len(_action({**MCP_ARGS, "to": "@bob"}).cards) == 1
    assert len(_action(server="matrix").cards) == 1


def test_a_rule_never_beats_the_money_floor_or_the_delegated_refusal(bot_home):
    assert _action(choice="always").error is None
    money = mcp_action_gate.ActionPolicy.from_config({"refused_tools": ["send_message"]})
    refused = _action(policy=money)
    assert json.loads(refused.error)["code"] == mcp_action_gate.ACTION_REFUSED and refused.cards == []
    with delegated_child_context("child"):
        child = _action()
    assert json.loads(child.error)["code"] == mcp_action_gate.APPROVAL_UNAVAILABLE


def test_a_rule_for_a_slack_channel_is_bound_to_the_workspace_not_only_its_name(slack, bot_home, monkeypatch):
    def post(choice):
        with Owner(choice=choice) as chat:
            _fresh_turn()
            result = json.loads(slack_tools.run_slack_tool(
                "slack_post_message", slack_tools._TOOLS["slack_post_message"][0],
                {"channel": routine.NAMED_ID, "text": "MRR is up"}))
        return result, chat.cards

    result, cards = post("always")
    assert result["sent"] is True and cards[0]["choices"] == OFFERED
    assert post("deny") == ({**result, "ts": "9.2"}, [])
    elsewhere = slack_tools.SlackInstall("T0OTHER", "Other", "vault-item-1")
    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: elsewhere)
    result, cards = post("deny")
    assert result.get("sent") is not True and len(cards) == 1 and len(slack) == 2


def _bot(root, name):
    home = root / "profiles" / name
    home.mkdir(parents=True)
    (home / "profile.yaml").write_text(textwrap.dedent("""\
        ui_meta:
          hermes-bots:
            shape: cloud
        """), encoding="utf-8")
    drafts._write_config(home)
    return home


def test_another_bot_is_asked_even_with_a_copy_of_the_rule_file(bot_home, monkeypatch):
    alpha, beta = _bot(bot_home, "alpha"), _bot(bot_home, "beta")
    monkeypatch.setenv("HERMES_HOME", str(alpha))
    _allow()
    shutil.copytree(alpha / "bot_mode", beta / "bot_mode")
    monkeypatch.setenv("HERMES_HOME", str(beta))
    assert send_rules.list_rules() == [] and len(_send().cards) == 1
    monkeypatch.setenv("HERMES_HOME", str(alpha))
    assert _send().cards == []


def test_revoke_removes_the_rule_and_the_next_send_asks_again(bot_home):
    _allow()
    [rule] = send_rules.list_rules()
    assert send_rules.revoke("sr_unknown") is False and len(send_rules.list_rules()) == 1
    assert send_rules.revoke(rule.id) is True and send_rules.revoke(rule.id) is False
    assert send_rules.list_rules() == [] and len(_send().cards) == 1


@pytest.mark.parametrize("content", ["not json", "[]", '{"rules": [{"id": 1}]}'])
def test_a_broken_rule_file_asks_and_is_never_overwritten(bot_home, content):
    path = bot_home / "bot_mode" / "send_rules.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(content, encoding="utf-8")
    sent = _send(choice="always")
    assert sent.block is None and len(sent.cards) == 1 and path.read_text(encoding="utf-8") == content


def _candidate(number):
    return send_rules.SendRuleCandidate(POST, f"signature-{number}", f"#c{number}", f"Send to #c{number} via Slack")


def test_the_rule_file_survives_a_reload_and_keeps_the_200_most_recently_used(bot_home):
    for number in range(200):
        send_rules.remember(_candidate(number))
    assert send_rules.allows(POST, "signature-0")
    send_rules.remember(_candidate(200))
    send_rules.remember(_candidate(200))
    signatures = {rule["signature"] for rule in json.loads(_stored(bot_home))["rules"]}
    assert len(signatures) == 200 and {"signature-0", "signature-200"} <= signatures
    assert "signature-1" not in signatures and len(send_rules.list_rules()) == 200


def test_rules_saved_at_the_same_time_are_all_kept(bot_home):
    token = set_session_vars()
    try:
        workers = [threading.Thread(target=send_rules.remember, args=(_candidate(n),)) for n in range(16)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=10)
    finally:
        clear_session_vars(token)
    assert len(send_rules.list_rules()) == 16


def test_the_file_tools_cannot_write_the_rules(bot_home):
    assert is_write_denied(str(bot_home / "bot_mode" / "send_rules.json"))
    assert not is_write_denied(str(bot_home / "bot_mode" / "settings.json"))
    from tools.file_tools import write_file_tool
    written = write_file_tool(str(bot_home / "bot_mode" / "send_rules.json"), '{"rules": []}')
    assert "denied" in written.lower() and _stored(bot_home) == ""
