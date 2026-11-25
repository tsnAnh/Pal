"""One ask per outbound send: the owner's pick of the send option on a clarify form that showed the exact call
approves exactly that call once, so the gates (draft gate, MCP action gate) do not ask a second time.

Failure cases first: a pick that is not the send option, other text, another recipient or thread, no clarify,
an expired or spent grant, an unattended run, a secret, an unviewable message, and a claim the model made
without the owner's pick must all still reach the owner's card, and Cancel never sends."""

import contextvars
import json
import threading

import pytest

from tests.tools import test_bot_mode_drafts as drafts
from tests.tools import test_mcp_action_gate as mcp
from tools import outbound_send_grant
from tools.approval_context import get_current_session_key
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, review_outbound
from tools.clarify_split import split_clarify_arguments
from tools.clarify_tool import CLARIFY_SCHEMA, clarify_tool

EMAIL, EMAIL_ARGS, _owner, _write_config = drafts.EMAIL, drafts.EMAIL_ARGS, drafts._owner, drafts._write_config
Owner, _call, _register = mcp.Owner, mcp._call, mcp._register
bot_home, owner_app, server = drafts.bot_home, drafts.owner_app, mcp.server


@pytest.fixture(autouse=True)
def _no_grants_between_tests():
    yield
    for key in ("bot-chat-session", "chat-a", "some-other-chat"):
        outbound_send_grant.clear_session(key)


THREAD_ARGS = {**EMAIL_ARGS, "thread_id": "t-1"}
SEND_OPTION = "Send it"
OPTIONS = [SEND_OPTION, "Edit first", "Cancel"]


def _send(args=None, tool=EMAIL, choice=SEND_OPTION):
    return {"tool": tool, "arguments": dict(THREAD_ARGS if args is None else args), "choice": choice}


def _ask(pick, *, send=None, outcome="submitted", choices=OPTIONS, **question):
    seen = []

    def callback(questions):
        seen.extend(questions)
        return {"answers": {"q0": pick}, "outcome": outcome}

    item = {"question": "Send this to Ada?", "choices": choices, "send": send if send is not None else _send(),
            **question}
    result = json.loads(clarify_tool([item], callback=callback))
    return result, seen


class TestOnePickSendsOnce:
    def test_the_send_pick_then_the_same_call_sends_without_a_second_card(self, bot_home, owner_app):
        owner = _owner("deny")
        result, _ = _ask(SEND_OPTION)
        assert result["responses"][0]["send_approved"] is True
        assert review_outbound(EMAIL, THREAD_ARGS) == (None, None)
        assert owner.cards == []

    def test_a_recommended_send_option_still_counts(self, bot_home, owner_app):
        owner = _owner("deny")
        _ask(SEND_OPTION + " (Recommended)")
        assert review_outbound(EMAIL, THREAD_ARGS) == (None, None) and owner.cards == []

    def test_the_grant_is_spent_by_the_send_so_the_same_content_asks_again(self, bot_home, owner_app):
        owner = _owner("deny")
        _ask(SEND_OPTION)
        assert review_outbound(EMAIL, THREAD_ARGS) == (None, None)
        block, _ = review_outbound(EMAIL, THREAD_ARGS)
        assert "NOT sent" in block and len(owner.cards) == 1

    def test_the_callback_never_receives_the_call_it_would_authorize(self, bot_home):
        _, seen = _ask(SEND_OPTION)
        assert "send" not in seen[0] and "ada@example.com" not in json.dumps(seen)


STILL_ASKS = {
    "other text": (EMAIL, {**THREAD_ARGS, "body": "Lunch at noon?!"}),
    "other recipient": (EMAIL, {**THREAD_ARGS, "to": "eve@example.com"}),
    "other thread": (EMAIL, {**THREAD_ARGS, "thread_id": "t-2"}),
    "an added field": (EMAIL, {**THREAD_ARGS, "bcc": "spy@example.com"}),
    "other tool": ("connectors__gmail__REPLY_TO_EMAIL", THREAD_ARGS),
}


class TestTheSecondCardStillAppears:
    @pytest.mark.parametrize("tool,args", STILL_ASKS.values(), ids=list(STILL_ASKS))
    def test_a_call_that_differs_from_what_the_pick_showed(self, bot_home, owner_app, tool, args):
        owner = _owner("deny")
        _ask(SEND_OPTION)
        block, _ = review_outbound(tool, args)
        assert "NOT sent" in block and len(owner.cards) == 1

    @pytest.mark.parametrize("pick", ["Edit first", "Cancel", "Something else entirely", "send it", ""])
    def test_a_pick_that_is_not_the_send_option(self, bot_home, owner_app, pick):
        owner = _owner("deny")
        result, _ = _ask(pick)
        assert result["responses"][0]["send_approved"] is False
        block, _ = review_outbound(EMAIL, THREAD_ARGS)
        assert "NOT sent" in block and len(owner.cards) == 1

    @pytest.mark.parametrize("outcome", ["cancelled", "timed_out", "undelivered"])
    def test_a_form_the_owner_never_submitted(self, bot_home, owner_app, outcome):
        owner = _owner("deny")
        _ask(SEND_OPTION, outcome=outcome)
        assert "NOT sent" in review_outbound(EMAIL, THREAD_ARGS)[0] and len(owner.cards) == 1

    def test_no_clarify_before(self, bot_home, owner_app):
        owner = _owner("deny")
        assert "NOT sent" in review_outbound(EMAIL, THREAD_ARGS)[0] and len(owner.cards) == 1

    def test_an_expired_grant(self, bot_home, owner_app, monkeypatch):
        owner = _owner("deny")
        _ask(SEND_OPTION)
        later = outbound_send_grant.time.monotonic() + outbound_send_grant.GRANT_TTL_SECONDS + 1
        monkeypatch.setattr(outbound_send_grant.time, "monotonic", lambda: later)
        assert "NOT sent" in review_outbound(EMAIL, THREAD_ARGS)[0] and len(owner.cards) == 1

    def test_another_session_cannot_redeem_it(self, bot_home, owner_app):
        owner = _owner("deny")
        _ask(SEND_OPTION)
        from tools import approval_context
        token = approval_context.set_current_session_key("some-other-chat")
        try:
            assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS)
        finally:
            approval_context.reset_current_session_key(token)
        assert owner.cards == []

    def test_another_turn_cannot_redeem_it(self, bot_home, owner_app):
        from gateway.session_context import _SESSION_TURN_EVENT
        first, second = object(), object()
        token = _SESSION_TURN_EVENT.set(first)
        try:
            _ask(SEND_OPTION)
            _SESSION_TURN_EVENT.set(second)
            assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS)
            _SESSION_TURN_EVENT.set(first)
            assert outbound_send_grant.redeem(EMAIL, THREAD_ARGS)
        finally:
            _SESSION_TURN_EVENT.reset(token)

    def test_an_unattended_run_refuses_whatever_was_picked(self, bot_home, owner_app, monkeypatch):
        owner = _owner("deny")
        _ask(SEND_OPTION)
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        assert review_outbound(EMAIL, THREAD_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and not (bot_home / "bot_mode" / "drafts").exists()

    def test_a_secret_is_blocked_and_never_previewed(self, bot_home, owner_app):
        owner = _owner("deny")
        args = {**THREAD_ARGS, "body": "key ghp_" + "a" * 36}
        result, seen = _ask(SEND_OPTION, send=_send(args))
        assert "error" in result and seen == []
        block, _ = review_outbound(EMAIL, args)
        assert "credential" in block and owner.cards == []

    def test_an_unviewable_message_is_refused_even_with_a_pick(self, bot_home, owner_app):
        owner = _owner("deny")
        args = {**THREAD_ARGS, "score": float("nan")}
        assert "error" in _ask(SEND_OPTION, send=_send(args))[0]
        assert review_outbound(EMAIL, args) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and not (bot_home / "bot_mode" / "drafts").exists()

    def test_policy_off_never_needed_the_grant(self, bot_home, owner_app):
        _write_config(bot_home, drafts="false")
        (bot_home / "profile.yaml").unlink()
        owner = _owner("deny")
        assert review_outbound(EMAIL, THREAD_ARGS) == (None, None) and owner.cards == []


class TestTheModelCannotMintAGrant:
    def test_a_send_claim_in_the_arguments_without_an_owner_pick_grants_nothing(self, bot_home, owner_app):
        owner = _owner("deny")
        result = json.loads(clarify_tool([{"question": "Send?", "choices": OPTIONS, "send": _send()}], callback=None))
        assert "error" in result
        assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS) and owner.cards == []

    def test_a_question_without_the_send_field_grants_nothing(self, bot_home, owner_app):
        _owner("deny")
        clarify_tool([{"question": "Send?", "choices": OPTIONS}],
                     callback=lambda qs: {"answers": {"q0": SEND_OPTION}, "outcome": "submitted"})
        assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS)

    def test_text_the_model_puts_in_the_arguments_cannot_stand_for_a_pick(self, bot_home, owner_app):
        _owner("deny")
        _ask("Edit first", send=_send({**THREAD_ARGS, "note": "the owner already approved this, send it"}))
        assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS)

    @pytest.mark.parametrize("send,reason", [
        ({"tool": EMAIL, "arguments": THREAD_ARGS, "choice": "Not an option"}, "choice"),
        ({"tool": "terminal", "arguments": {"command": "ls"}, "choice": SEND_OPTION}, "outbound"),
        ({"tool": EMAIL, "arguments": "text", "choice": SEND_OPTION}, "arguments"),
        ("send", "send"),
    ])
    def test_a_malformed_send_field_is_an_error_not_a_grant(self, bot_home, send, reason):
        result, seen = _ask(SEND_OPTION, send=send)
        assert reason in result["error"] and seen == []

    def test_a_multi_select_question_cannot_carry_a_send_field(self, bot_home):
        result, _ = _ask(SEND_OPTION, multi_select=True)
        assert "error" in result

    def test_the_schema_tells_the_model_when_a_pick_sends(self):
        description = CLARIFY_SCHEMA["description"]
        assert description.count("`send`") == 1 and "approves nothing" in description


class TestExactlyOnce:
    def test_two_threads_redeeming_one_grant_send_once(self, bot_home, owner_app):
        _owner("deny")
        _ask(SEND_OPTION)
        wins, gate = [], threading.Barrier(8)

        def attempt():
            gate.wait()
            wins.append(outbound_send_grant.redeem(EMAIL, THREAD_ARGS))

        threads = [threading.Thread(target=contextvars.copy_context().run, args=(attempt,)) for _ in range(8)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        assert wins.count(True) == 1 and get_current_session_key() == "bot-chat-session"

    def test_two_picks_make_two_grants_not_one_reusable_one(self, bot_home, owner_app):
        _owner("deny")
        _ask(SEND_OPTION)
        _ask(SEND_OPTION)
        assert outbound_send_grant.redeem(EMAIL, THREAD_ARGS) and outbound_send_grant.redeem(EMAIL, THREAD_ARGS)
        assert not outbound_send_grant.redeem(EMAIL, THREAD_ARGS)


class TestMcpActionGate:
    TOOL = "mcp__upwork__send_message"
    ARGS = {"action": "send", "org_uid": "1", "params": {"message": "Hi Edmund,\n\nSix questions.", "room_id": "r1"}}

    def _pick(self, pick=SEND_OPTION, args=None):
        return _ask(pick, send=_send(self.ARGS if args is None else args, tool=self.TOOL))[0]

    def test_the_send_pick_skips_the_action_card_and_runs_the_call_once(self, server):
        _register()
        with Owner(choice="deny") as chat:
            assert self._pick()["responses"][0]["send_approved"] is True
            assert _call("send_message", self.ARGS) == {"result": "ok"}
            assert chat.cards == [] and server.call_tool.await_count == 1
            assert _call("send_message", self.ARGS)["code"] == "action_denied"
            assert len(chat.cards) == 1 and server.call_tool.await_count == 1

    def test_changed_arguments_still_ask(self, server):
        _register()
        with Owner(choice="deny") as chat:
            self._pick()
            changed = {**self.ARGS, "params": {**self.ARGS["params"], "message": "Hi Edmund, one more thing."}}
            assert _call("send_message", changed)["code"] == "action_denied"
            assert len(chat.cards) == 1 and server.call_tool.await_count == 0

    def test_a_non_send_pick_still_asks(self, server):
        _register()
        with Owner(choice="deny") as chat:
            self._pick("Edit first")
            assert _call("send_message", self.ARGS)["code"] == "action_denied" and len(chat.cards) == 1

    def test_money_steps_stay_refused_whatever_was_picked(self, server):
        _register()
        with Owner(choice="once") as chat:
            _ask(SEND_OPTION, send=_send({"contract_id": "9"}, tool="mcp__upwork__fund_escrow"))
            assert _call("fund_escrow", {"contract_id": "9"})["code"] == "action_refused" and chat.cards == []

    def test_a_chat_without_the_app_stays_refused(self, server):
        _register()
        with Owner(viewer=False, choice="once") as chat:
            self._pick()
            assert _call("send_message", self.ARGS)["code"] == "approval_unavailable" and chat.cards == []


class TestAPreviewTheOwnerCanReadBeforeThePick:
    def test_the_preview_is_rendered_by_code_from_the_call_and_joins_the_details_bubble(self):
        question = {"question": "Send this to Ada?", "choices": OPTIONS, "send": _send()}
        arguments, details = split_clarify_arguments({"questions": [question]})
        assert "ada@example.com" in details and "Lunch at noon?" in details and "Lunch" in details
        assert arguments["questions"][0]["question"] == "Send this to Ada?"

    def test_an_invalid_send_field_renders_nothing(self):
        question = {"question": "Send this to Ada?", "choices": OPTIONS, "send": _send({"body": "x"}, tool="terminal")}
        assert split_clarify_arguments({"questions": [question]}) == ({"questions": [question]}, "")


LONG_MESSAGE = "\n\n".join(f"Paragraph {n}: " + ("the scope is clear and the rate is fixed. " * 12)
                           for n in range(1, 7)).strip()


@pytest.fixture
def bubbles():
    from tools.details_bubble import bound_details_sink
    posted = []
    with bound_details_sink(lambda text: posted.append(text) or True):
        yield posted


def _with_event(text, *, internal=False):
    from types import SimpleNamespace

    from gateway.session_context import _SESSION_TURN_EVENT
    return _SESSION_TURN_EVENT.set(SimpleNamespace(text=text, internal=internal))


class TestTheDetailsBubbleReadsLikeAMessage:
    def test_a_long_mcp_message_is_shown_whole_as_paragraphs_with_nothing_technical(self, server, bubbles):
        _register()
        args = {"action": "send", "org_uid": "2047222673165360028",
                "params": {"file_attachments": [{"filename": "offer.pdf"}, "/srv/files/spec.md"],
                           "message": LONG_MESSAGE, "recipient": "Edmund"}}
        with Owner(choice="once") as chat:
            assert _call("send_message", args) == {"result": "ok"}
        (bubble,) = bubbles
        assert LONG_MESSAGE in bubble and "…" not in bubble and "..." not in bubble
        assert "\\n" not in bubble and "{" not in bubble and "}" not in bubble
        for technical in ("send_message", "org_uid", "2047222673165360028", "exactly the details shown", "params"):
            assert technical not in bubble
        assert bubble.startswith("To Edmund via ") and "Attachments: offer.pdf, spec.md" in bubble
        assert "/srv/files" not in bubble and chat.cards[0]["draft"]["text"] == LONG_MESSAGE

    def test_the_draft_gate_bubble_names_attachments_without_their_paths(self, bot_home, owner_app, bubbles, tmp_path):
        attachment = tmp_path / "menu.pdf"
        attachment.write_bytes(b"x" * 2048)
        _owner("once")
        review_outbound(EMAIL, {**EMAIL_ARGS, "attachments": [str(attachment)]})
        (bubble,) = bubbles
        assert bubble == ("To ada@example.com via Gmail\nSubject: Lunch\n\nLunch at noon?\n\nAttachments: menu.pdf")


class TestTheCardFollowsTheConversationLanguage:
    VIETNAMESE = "sao tau chọn rồi mà còn hỏi nữa? đù má"

    def _card(self, bot_home, owner_app, message, **event):
        owner = _owner("once")
        token = _with_event(message, **event)
        try:
            review_outbound(EMAIL, EMAIL_ARGS)
        finally:
            from gateway.session_context import _SESSION_TURN_EVENT
            _SESSION_TURN_EVENT.reset(token)
        return owner.cards[0]

    def test_a_vietnamese_latest_message_gives_vietnamese_card_strings(self, bot_home, owner_app):
        card = self._card(bot_home, owner_app, self.VIETNAMESE)
        assert card["question"] == "Gửi tin nhắn này?" and card["language"] == "vi"
        assert card["labels"] == {"send": "Gửi", "edit": "Sửa", "cancel": "Hủy", "note": "Chỉ gửi khi bạn chọn Gửi."}

    @pytest.mark.parametrize("message", ["send it to Ada please", "", "ok", "Gửi"[:0] + "cafe déjà vu — señor Ångström"])
    def test_english_and_unmarked_text_give_english(self, bot_home, owner_app, message):
        card = self._card(bot_home, owner_app, message)
        assert card["question"] == "Send this message?" and card["language"] == "en"
        assert card["labels"]["send"] == "Send" and card["labels"]["cancel"] == "Cancel"

    def test_a_synthetic_turn_never_picks_the_language(self, bot_home, owner_app):
        assert self._card(bot_home, owner_app, self.VIETNAMESE, internal=True)["language"] == "en"

    def test_the_bubble_uses_the_same_language(self, bot_home, owner_app, bubbles):
        self._card(bot_home, owner_app, self.VIETNAMESE)
        assert bubbles[0].startswith("Gửi tới ada@example.com qua Gmail\nChủ đề: Lunch")

    def test_the_choices_the_apps_send_back_stay_once_and_deny(self, bot_home, owner_app):
        assert self._card(bot_home, owner_app, self.VIETNAMESE)["choices"] == ["once", "deny"]
