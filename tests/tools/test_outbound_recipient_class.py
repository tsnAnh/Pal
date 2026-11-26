import logging

import pytest

from tests.tools import test_bot_mode_drafts as drafts
from tools import approval, approval_context
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, review_outbound

EMAIL, EMAIL_ARGS, _write_config = drafts.EMAIL, drafts.EMAIL_ARGS, drafts._write_config
bot_home, owner_app = drafts.bot_home, drafts.owner_app

OWN_AGENT_TOOL = "mcp__t3code__t3_thread_send"
OWN_AGENT_ARGS = {"threadId": "t1", "message": "private plan for tomorrow"}


@pytest.fixture
def asked(monkeypatch):
    calls = []

    def answer(**kwargs):
        calls.append(kwargs)
        return {"approved": True}

    monkeypatch.setattr(approval, "request_draft_approval", answer)
    return calls


def _no_drafts_dir(home):
    return not (home / "bot_mode" / "drafts").exists()


class TestOwnAgentSends:
    @pytest.mark.parametrize("tool", ["mcp__t3code__t3_thread_send", "mcp__t3code__t3_thread_send_attachments"])
    def test_a_send_to_the_own_agent_goes_through_without_an_ask(self, bot_home, owner_app, asked, tool):
        assert review_outbound(tool, OWN_AGENT_ARGS) == (None, None)
        assert asked == [] and _no_drafts_dir(bot_home)

    def test_the_pass_is_logged_with_tool_and_class_but_never_the_text(self, bot_home, owner_app, asked, caplog):
        with caplog.at_level(logging.INFO, logger="tools.bot_mode_drafts"):
            assert review_outbound(OWN_AGENT_TOOL, OWN_AGENT_ARGS) == (None, None)
        lines = [record.getMessage() for record in caplog.records if "own_agent" in record.getMessage()]
        assert len(lines) == 1 and "t3_thread_send" in lines[0]
        assert OWN_AGENT_ARGS["message"] not in caplog.text

    def test_a_secret_in_an_own_agent_send_is_still_blocked(self, bot_home, owner_app, asked):
        block, _ = review_outbound(OWN_AGENT_TOOL, {**OWN_AGENT_ARGS, "message": "key ghp_" + "a" * 36})
        assert "credential" in block and asked == []

    def test_another_t3_tool_is_not_the_own_agent(self, bot_home, owner_app, asked):
        assert review_outbound("mcp__t3code__t3_thread_send_attachments_elsewhere", OWN_AGENT_ARGS) == (None, None)
        assert asked != []


class TestPersonSends:
    def test_an_attended_send_asks_exactly_once_and_stores_nothing(self, bot_home, owner_app, asked):
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert len(asked) == 1 and _no_drafts_dir(bot_home)

    def test_an_unattended_send_is_refused_without_asking_or_storing(self, bot_home, owner_app, asked, monkeypatch):
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        assert approval_context._no_user_can_answer()
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert asked == [] and _no_drafts_dir(bot_home)

    def test_no_inline_capable_client_refuses_without_storing(self, bot_home, asked):
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert asked == [] and _no_drafts_dir(bot_home)

    def test_an_unviewable_message_refuses_without_storing(self, bot_home, owner_app, asked):
        assert review_outbound(EMAIL, {**EMAIL_ARGS, "score": float("nan")}) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert asked == [] and _no_drafts_dir(bot_home)

    def test_an_owner_timeout_refuses_without_storing(self, bot_home, owner_app, monkeypatch):
        monkeypatch.setattr(approval, "request_draft_approval", lambda **kw: {"approved": False, "outcome": "timeout"})
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert _no_drafts_dir(bot_home)


class TestOwnerRecipients:
    def test_a_listed_recipient_goes_through_without_an_ask(self, bot_home, owner_app, asked):
        _write_config(bot_home, owner_recipients='["ada@example.com"]')
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert asked == [] and _no_drafts_dir(bot_home)

    def test_an_unlisted_recipient_still_asks(self, bot_home, owner_app, asked):
        _write_config(bot_home, owner_recipients='["ada@example.com"]')
        assert review_outbound(EMAIL, {**EMAIL_ARGS, "to": "eve@example.com"}) == (None, None)
        assert len(asked) == 1

    def test_the_match_is_exact_not_a_substring(self, bot_home, owner_app, asked):
        _write_config(bot_home, owner_recipients='["ada@example.com"]')
        assert review_outbound(EMAIL, {**EMAIL_ARGS, "to": "ada@example.com.evil.test"}) == (None, None)
        assert len(asked) == 1

    def test_a_free_text_recipient_that_mentions_a_t3_thread_is_not_the_own_agent(self, bot_home, owner_app, asked):
        args = {"to": "t3code thread t1", "message": "hello"}
        assert review_outbound("mcp__fakeconn__fakeconn__send_message", args) == (None, None)
        assert len(asked) == 1
