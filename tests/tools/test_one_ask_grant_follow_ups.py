"""The owner's one pick on a clarify `send` form is the only ask, with the real Upwork message call.

Failure cases first: the pick arriving in a later turn, both gates of one call (the draft gate and the MCP gate
each ask when the tool name carries a send word), spelling-only differences between the form's call and the real
call, a changed recipient or text, an added recipient, expiry, a second spend, another chat, a log line that leaks
the message, and an approval preview that shows the call's JSON instead of the message."""

import json
import logging

import pytest

from tests.tools import test_bot_mode_drafts as drafts
from tests.tools import test_mcp_action_gate as mcp
from tests.tools.test_one_ask_outbound_send import OPTIONS, SEND_OPTION, _ask, _send
from tools import outbound_send_grant
from tools.bot_mode_drafts import classify_outbound, review_outbound
from tools.mcp_action_gate import build_card

Owner, _call, _register, server = mcp.Owner, mcp._call, mcp._register, mcp.server
bot_home, owner_app, SESSION = drafts.bot_home, drafts.owner_app, drafts.SESSION

RAW_TOOL = "upwork__send_message"
WIRE_TOOL = "mcp__upwork__upwork__send_message"
BODY = "Hi Teimoor,\n\nThanks for the detail on the scope. I can start Monday.\n\nBest,\nAnh"
ROOM = "room_f1ca0877fe46d74198451a89ac4167ae"
ORG = "2047222673165360028"
UPWORK_ARGS = {"action": "send", "org_uid": ORG, "params": {"room_id": ROOM, "message": BODY, "file_attachments": []}}


@pytest.fixture(autouse=True)
def _no_grants_between_tests():
    yield
    for key in (SESSION, "chat-a", "some-other-chat"):
        outbound_send_grant.clear_session(key)


def _pick(args=None, tool=WIRE_TOOL):
    return _ask(SEND_OPTION, send=_send(UPWORK_ARGS if args is None else args, tool=tool))[0]


class TestTheRealUpworkSendAsksOnce:
    def test_the_pick_then_both_gates_run_the_call_without_any_card(self, bot_home, owner_app, server):
        _register(tools=(RAW_TOOL,))
        with Owner(key=SESSION, choice="deny") as chat:
            assert _pick()["responses"][0]["send_approved"] is True
            assert review_outbound(WIRE_TOOL, UPWORK_ARGS) == (None, None)
            assert _call(RAW_TOOL, UPWORK_ARGS) == {"result": "ok"}
            assert chat.cards == [] and server.call_tool.await_count == 1

    def test_the_answer_arriving_as_a_later_turn_still_sends_without_a_card(self, bot_home, owner_app, server):
        from types import SimpleNamespace

        from gateway.session_context import _SESSION_TURN_EVENT
        _register(tools=(RAW_TOOL,))
        with Owner(key=SESSION, choice="deny") as chat:
            first = _SESSION_TURN_EVENT.set(SimpleNamespace(text="ask me", internal=False))
            try:
                _pick()
            finally:
                _SESSION_TURN_EVENT.reset(first)
            later = _SESSION_TURN_EVENT.set(SimpleNamespace(text="Send it", internal=False))
            try:
                assert review_outbound(WIRE_TOOL, UPWORK_ARGS) == (None, None)
                assert _call(RAW_TOOL, UPWORK_ARGS) == {"result": "ok"}
            finally:
                _SESSION_TURN_EVENT.reset(later)
            assert chat.cards == []

    def test_the_send_runs_once_then_the_same_call_asks_again(self, bot_home, owner_app, server):
        _register(tools=(RAW_TOOL,))
        with Owner(key=SESSION, choice="deny") as chat:
            _pick()
            assert _call(RAW_TOOL, UPWORK_ARGS) == {"result": "ok"}
            assert _call(RAW_TOOL, UPWORK_ARGS)["code"] == "action_denied" and len(chat.cards) == 1
            assert server.call_tool.await_count == 1


SPELLINGS = {
    "key order": {"params": {"message": BODY, "file_attachments": [], "room_id": ROOM}, "org_uid": ORG, "action": "send"},
    "integer id": {**UPWORK_ARGS, "org_uid": int(ORG)},
    "padded text": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "message": f"  {BODY}\n\n"}},
    "literal newline escapes": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "message": BODY.replace("\n", "\\n")}},
    "crlf": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "message": BODY.replace("\n", "\r\n")}},
    "attachments missing": {**UPWORK_ARGS, "params": {"room_id": ROOM, "message": BODY}},
    "attachments null": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "file_attachments": None}},
    "params hoisted": {"action": "send", "org_uid": ORG, "room_id": ROOM, "message": BODY, "file_attachments": []},
    "an unrelated field differs": {**UPWORK_ARGS, "client_request_id": "abc-123", "org_uid": "other-org"},
}


class TestSpellingNeverCostsASecondAsk:
    @pytest.mark.parametrize("real", SPELLINGS.values(), ids=list(SPELLINGS))
    def test_the_form_side_call_and_the_gate_side_call_are_one_call(self, bot_home, owner_app, real):
        _pick()
        assert outbound_send_grant.redeem(WIRE_TOOL, real)

    @pytest.mark.parametrize("shown", SPELLINGS.values(), ids=list(SPELLINGS))
    def test_a_form_spelled_either_way_grants_the_plain_call(self, bot_home, owner_app, shown):
        _pick(shown)
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)

    def test_the_two_spellings_normalise_to_one_digest(self):
        forms = {json.dumps(outbound_send_grant.normalise(WIRE_TOOL, args), sort_keys=True)
                 for args in (UPWORK_ARGS, SPELLINGS["key order"], SPELLINGS["literal newline escapes"])}
        assert len(forms) == 1


STILL_ASKS = {
    "other room": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "room_id": "room_other"}},
    "other text": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "message": BODY + "\nP.S. Call me."}},
    "added recipient": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "bcc": "spy@example.com"}},
    "added attachment": {**UPWORK_ARGS, "params": {**UPWORK_ARGS["params"], "file_attachments": ["/tmp/cv.pdf"]}},
}


class TestAnythingThatChangesWhoOrWhatStillAsks:
    @pytest.mark.parametrize("real", STILL_ASKS.values(), ids=list(STILL_ASKS))
    def test_a_changed_call(self, bot_home, owner_app, real):
        _pick()
        assert not outbound_send_grant.redeem(WIRE_TOOL, real)
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)

    def test_another_tool(self, bot_home, owner_app):
        _pick()
        assert not outbound_send_grant.redeem("mcp__upwork__upwork__submit_proposal", UPWORK_ARGS)

    def test_another_chat(self, bot_home, owner_app):
        from tools import approval_context
        _pick()
        token = approval_context.set_current_session_key("some-other-chat")
        try:
            assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        finally:
            approval_context.reset_current_session_key(token)

    def test_expiry(self, bot_home, owner_app, monkeypatch):
        _pick()
        later = outbound_send_grant.time.monotonic() + outbound_send_grant.GRANT_TTL_SECONDS + 1
        monkeypatch.setattr(outbound_send_grant.time, "monotonic", lambda: later)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)

    def test_one_shot(self, bot_home, owner_app):
        _pick()
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)

    def test_a_draft_gate_spend_lets_only_the_mcp_gate_of_that_call_through_after_it(self, bot_home, owner_app):
        _pick()
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS, gate=outbound_send_grant.DRAFT_GATE)
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS, gate=outbound_send_grant.MCP_GATE)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS, gate=outbound_send_grant.MCP_GATE)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS, gate=outbound_send_grant.DRAFT_GATE)


class TestOneLogLineReadsTheOutcome:
    def _lines(self, caplog):
        return [r.getMessage() for r in caplog.records if r.getMessage().startswith("send_grant")]

    def test_issued_redeemed_and_each_miss_reason(self, bot_home, owner_app, caplog, monkeypatch):
        from tools import approval_context
        caplog.set_level(logging.WARNING)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        _pick()
        assert not outbound_send_grant.redeem(WIRE_TOOL, STILL_ASKS["other text"])
        token = approval_context.set_current_session_key("some-other-chat")
        try:
            assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        finally:
            approval_context.reset_current_session_key(token)
        assert outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        later = outbound_send_grant.time.monotonic() + outbound_send_grant.GRANT_TTL_SECONDS + 1
        _pick()
        monkeypatch.setattr(outbound_send_grant.time, "monotonic", lambda: later)
        assert not outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        lines = self._lines(caplog)
        wanted = ["send_grant miss", "send_grant issued", "send_grant miss", "send_grant miss", "send_grant redeemed",
                  "send_grant issued", "send_grant miss"]
        assert [line.split(" tool=")[0] for line in lines] == wanted
        reasons = [line.split("reason=")[1].split()[0] for line in lines if "reason=" in line]
        assert reasons == ["no_grant", "digest_mismatch", "other_session", "expired"]
        assert all(r.levelno == logging.WARNING for r in caplog.records if r.getMessage().startswith("send_grant"))

    def test_no_line_carries_the_message_or_the_ids_or_the_session_key(self, bot_home, owner_app, caplog):
        caplog.set_level(logging.DEBUG)
        _pick()
        outbound_send_grant.redeem(WIRE_TOOL, STILL_ASKS["other text"])
        outbound_send_grant.redeem(WIRE_TOOL, UPWORK_ARGS)
        text = "\n".join(self._lines(caplog))
        assert text
        for private in ("Teimoor", "Monday", ROOM, ORG, SESSION):
            assert private not in text
class TestTheApprovalReadsLikeAMessage:
    def _assert_human(self, text, shown):
        assert text == BODY and "\n\n" in text and "\\n" not in text
        main = "\n".join([text, *(f"{d['name']}" for d in shown)])
        assert "org_uid" not in main and ORG not in main and ROOM not in main and "{" not in main

    def test_the_draft_gate_card_shows_the_message_with_real_line_breaks(self, bot_home, owner_app):
        outbound = classify_outbound(WIRE_TOOL, UPWORK_ARGS)
        self._assert_human(outbound.text, [{"name": n} for n, _ in outbound.details])
        assert outbound.viewable and not outbound.editable
        technical = [value for name, value in outbound.details if ROOM in value]
        assert len(technical) == 1 and "{" not in technical[0] and "\\n" not in technical[0]

    def test_the_mcp_gate_card_shows_the_message_with_real_line_breaks(self):
        card = build_card("upwork", RAW_TOOL, UPWORK_ARGS)
        self._assert_human(card["text"], card["details"])
        assert "{" not in json.dumps([d["value"] for d in card["details"]]).replace("{}", "")
        assert [d for d in card["details"] if ROOM in d["value"]] and sum(ROOM in d["value"] for d in card["details"]) == 1
        assert ROOM not in card["description"] and ORG not in card["description"]

    def test_a_named_recipient_and_attachment_names_are_the_readable_parts(self):
        args = {"action": "send", "org_uid": ORG, "params": {
            "room_id": ROOM, "room_title": "Teimoor K.", "message": BODY, "file_attachments": ["/srv/files/offer.pdf"]}}
        card = build_card("upwork", RAW_TOOL, args)
        assert card["draft"]["recipient"] == "Teimoor K." and card["attachments"] == ("offer.pdf",)
        assert ROOM not in card["text"] and "/srv/files" not in json.dumps(card["details"][:-1])
        outbound = classify_outbound(WIRE_TOOL, args)
        assert outbound.recipient == "Teimoor K." and ROOM not in outbound.text

    @pytest.mark.parametrize("key", ["text", "body", "content"])
    def test_an_unknown_tool_finds_the_body_under_another_name(self, key):
        card = build_card("other", "post_reply", {"params": {key: BODY, "to": "Ada"}})
        assert card["text"] == BODY and card["draft"]["recipient"] == "Ada"

    def test_the_json_fallback_is_a_code_block_and_only_without_a_body(self):
        card = build_card("other", "do_thing", {"mode": "fast", "items": [1, 2]})
        assert "mode" in card["text"]
        outbound = classify_outbound("mcp__other__post_update", {"mode": "fast", "items": [1, 2]})
        assert outbound.text.startswith("```json\n") and outbound.text.endswith("\n```")
