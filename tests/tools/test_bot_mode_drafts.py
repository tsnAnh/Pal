import json
import textwrap

import pytest

import hermes_cli.config as hc
from tools import approval, approval_context, bot_mode_draft_store
from tools.bot_mode_drafts import classify_outbound, review_outbound

SESSION = "bot-chat-session"
EMAIL = "connectors__gmail__SEND_EMAIL"
EMAIL_ARGS = {"to": "ada@example.com", "subject": "Lunch", "body": "Lunch at noon?"}


def _write_config(home, **bot_mode):
    lines = ["approvals:\n  mode: manual\n  timeout: 2\ncommand_allowlist: []\n"]
    if bot_mode:
        lines.append("bot_mode:\n" + "".join(f"  {k}: {v}\n" for k, v in bot_mode.items()))
    (home / "config.yaml").write_text("".join(lines), encoding="utf-8")
    hc._LOAD_CONFIG_CACHE.clear()


@pytest.fixture
def bot_home(tmp_path, monkeypatch):
    home = tmp_path / "hermes"
    home.mkdir()
    (home / "profile.yaml").write_text(
        textwrap.dedent("""\
            ui_meta:
              hermes-bots:
                shape: cloud
        """), encoding="utf-8")
    _write_config(home)
    monkeypatch.setenv("HERMES_HOME", str(home))
    for name in ("HERMES_CRON_SESSION", "HERMES_SINGLE_QUERY_SESSION", "HERMES_YOLO_MODE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HERMES_GATEWAY_SESSION", "1")
    monkeypatch.setenv("HERMES_EXEC_ASK", "1")
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    monkeypatch.setattr(approval, "_YOLO_MODE_FROZEN", False, raising=False)
    monkeypatch.setattr("tools.terminal_tool._get_approval_callback", lambda: None, raising=False)
    tokens = [approval_context.set_current_session_key(SESSION),
              approval_context.set_current_observability_context(turn_id="turn-1")]
    yield home
    approval_context.reset_current_observability_context(tokens[1])
    approval_context.reset_current_session_key(tokens[0])
    approval.unregister_gateway_notify(SESSION)
    approval.clear_session(SESSION)
    hc._LOAD_CONFIG_CACHE.clear()


@pytest.fixture
def bot_chat():
    token = approval_context.set_current_bot_chat(True)
    yield
    approval_context.reset_current_bot_chat(token)


class Owner:

    def __init__(self, *answers):
        self.answers = list(answers)
        self.cards = []

    def __call__(self, data):
        self.cards.append(data)
        answer = self.answers.pop(0) if self.answers else None
        if answer is None:
            return
        choice, edited = answer if isinstance(answer, tuple) else (answer, None)
        assert approval.resolve_gateway_approval(
            SESSION, choice, request_id=data["request_id"], edited_text=edited) == 1


def _owner(*answers):
    owner = Owner(*answers)
    approval.register_gateway_notify(SESSION, owner)
    return owner


def _ask_tool_approval(rule="k"):
    return approval.request_tool_approval("home_lock", "unlock the front door", rule_key=rule)


class TestBotChatApprovals:
    def test_card_offers_exactly_once_always_deny(self, bot_home, bot_chat):
        owner = _owner("once")
        assert _ask_tool_approval()["approved"] is True
        assert owner.cards[0]["choices"] == ["once", "always", "deny"]
        assert owner.cards[0]["scope"] == "bot_chat"

    def test_other_chats_keep_their_choices(self, bot_home):
        owner = _owner("once")
        assert _ask_tool_approval()["approved"] is True
        assert "choices" not in owner.cards[0] and "scope" not in owner.cards[0]

    def test_a_stray_session_answer_is_one_use_never_forever(self, bot_home, bot_chat):
        owner = _owner("session", "once")
        assert _ask_tool_approval()["approved"] is True
        assert _ask_tool_approval()["approved"] is True
        assert len(owner.cards) == 2

    def test_always_allow_persists_for_the_profile(self, bot_home, bot_chat):
        owner = _owner("always")
        assert _ask_tool_approval()["approved"] is True
        assert "plugin_rule:k" in hc.load_config().get("command_allowlist", [])
        assert _ask_tool_approval()["approved"] is True
        assert len(owner.cards) == 1

    def test_deny_is_not_retried_until_the_next_message(self, bot_home, bot_chat):
        owner = _owner("deny", "once")
        first = _ask_tool_approval()
        assert first["approved"] is False and first["outcome"] == "denied"
        retry = _ask_tool_approval()
        assert retry["approved"] is False and retry["outcome"] == "denied"
        assert "next message" in retry["message"]
        assert len(owner.cards) == 1
        tokens = approval_context.set_current_observability_context(turn_id="turn-2")
        try:
            assert _ask_tool_approval()["approved"] is True
        finally:
            approval_context.reset_current_observability_context(tokens)
        assert len(owner.cards) == 2

    def test_deny_outside_the_bot_chat_asks_again(self, bot_home):
        owner = _owner("deny", "once")
        assert _ask_tool_approval()["approved"] is False
        assert _ask_tool_approval()["approved"] is True
        assert len(owner.cards) == 2


class TestClassification:
    @pytest.mark.parametrize("tool,args", [
        (EMAIL, EMAIL_ARGS),
        ("connectors__slack__POST_MESSAGE", {"channel": "C1", "text": "hi"}),
        ("connectors__gmail__REPLY_TO_THREAD", {"thread_id": "t", "body": "ok"}),
        ("connectors__gmail__SEND_DRAFT", {"draft_id": "d"}),
        ("mcp__telegram__send_message", {"chat_id": "1", "text": "hi"}),
        ("send_message", {"action": "send", "target": "telegram:123", "message": "hi"}),
    ])
    def test_sends_are_outbound(self, tool, args):
        assert classify_outbound(tool, args) is not None

    @pytest.mark.parametrize("tool,args", [
        ("connectors__gmail__CREATE_EMAIL_DRAFT", {"body": "x"}),
        ("connectors__gmail__LIST_THREADS", {}),
        ("connectors__gmail__GET_MESSAGE", {"id": "1"}),
        ("connectors__slack__DELETE_MESSAGE", {"ts": "1"}),
        ("mcp__github__search_issues", {"query": "x"}),
        ("send_message", {"action": "list"}),
        ("react_to_message", {"emoji": "x"}),
        ("message_agent", {"target": "@scribe", "message": "hi"}),
        ("terminal", {"command": "ls"}),
    ])
    def test_reads_drafts_and_bot_to_bot_are_not(self, tool, args):
        assert classify_outbound(tool, args) is None

    def test_card_shows_recipient_channel_subject_and_the_whole_text(self):
        outbound = classify_outbound(EMAIL, EMAIL_ARGS)
        assert (outbound.channel, outbound.recipient, outbound.subject, outbound.text, outbound.editable) == (
            "Gmail", "ada@example.com", "Lunch", "Lunch at noon?", True)

    def test_a_send_without_a_text_field_shows_every_argument_and_is_not_editable(self):
        outbound = classify_outbound("connectors__gmail__SEND_DRAFT", {"draft_id": "d1"})
        assert json.loads(outbound.text) == {"draft_id": "d1"} and not outbound.editable


class TestAttendedDrafts:
    def test_send_runs_the_call_as_drafted(self, bot_home, bot_chat):
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        card = owner.cards[0]
        assert card["choices"] == ["once", "deny"]
        assert card["command"] == EMAIL_ARGS["body"]
        assert card["draft"] == {"kind": "outbound_message", "channel": "Gmail", "recipient": "ada@example.com",
                                 "subject": "Lunch", "text": "Lunch at noon?", "editable": True, "held": False}
        assert card["allow_session"] is False and card["allow_permanent"] is False

    def test_discard_is_final_and_tells_the_agent_not_to_retry(self, bot_home, bot_chat):
        owner = _owner("deny", "once")
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert args is None and "NOT sent" in block and "Do NOT retry" in block
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, "body": "Lunch at one?"})
        assert block is not None and len(owner.cards) == 1
        assert bot_mode_draft_store.list_pending() == []

    def test_edit_then_send_sends_the_edited_text(self, bot_home, bot_chat):
        _owner(("once", "Lunch at one instead?"))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert block is None
        assert args == {**EMAIL_ARGS, "body": "Lunch at one instead?"}

    @pytest.mark.parametrize("edit", ["   ", "x" * 100_001, "token ghp_" + "a" * 36])
    def test_an_invalid_edit_is_revalidated_and_nothing_is_sent(self, bot_home, bot_chat, edit):
        _owner(("once", edit))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert block is not None and args is None and "NOT sent" in block

    def test_an_edit_cannot_change_where_the_message_goes(self, bot_home):
        outbound = classify_outbound(EMAIL, EMAIL_ARGS)
        from tools.bot_mode_drafts import validate_edit
        assert validate_edit(outbound, EMAIL_ARGS, "new text")[0] == {**EMAIL_ARGS, "body": "new text"}
        assert validate_edit(classify_outbound("connectors__gmail__SEND_DRAFT", {"draft_id": "d"}),
                             {"draft_id": "d"}, "x")[0] is None

    def test_a_secret_in_the_body_is_refused_without_a_draft(self, bot_home, bot_chat):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, "body": "key ghp_" + "a" * 36})
        assert "credential" in block and owner.cards == []
        assert bot_mode_draft_store.list_pending() == []

    def test_no_answer_never_sends_and_keeps_the_draft(self, bot_home, bot_chat):
        owner = _owner(None)
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert args is None and "NOT sent" in block and len(owner.cards) == 1
        held = bot_mode_draft_store.list_pending()
        assert len(held) == 1 and held[0]["text"] == EMAIL_ARGS["body"] and held[0]["origin"] == "timeout"


class TestToolCallPipeline:
    def test_the_real_pre_tool_call_dispatch_applies_an_edited_send(self, bot_home, bot_chat):
        from hermes_cli.plugins import _dispatch_pre_tool_call_hooks
        _owner(("once", "Lunch at one?"))
        block, args = _dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert block is None and args == {**EMAIL_ARGS, "body": "Lunch at one?"}

    def test_the_real_pre_tool_call_dispatch_blocks_a_discarded_send(self, bot_home, bot_chat):
        from hermes_cli.plugins import _dispatch_pre_tool_call_hooks
        _owner("deny")
        block, args = _dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert "NOT sent" in block and args is None

    def test_a_connector_batch_entry_is_drafted_and_never_reaches_the_wire(self, bot_home, bot_chat, monkeypatch):
        import model_tools
        from tools.connectors.gateway import bridge, config
        monkeypatch.setattr(config, "connectors_available", lambda: True)
        monkeypatch.setattr(bridge, "connectors_available", lambda: True)
        wire = []

        class Client:
            def execute(self, planned):
                wire.extend(planned)
                return [{"data": "remote-ok", "error": None} for _ in planned]

        monkeypatch.setattr(bridge, "_default_client_factory", lambda call=None: Client())
        _owner("deny")
        result = json.loads(model_tools.handle_function_call(
            "tool_call", {"calls": [{"name": EMAIL, "arguments": dict(EMAIL_ARGS)}]},
            enabled_toolsets=["connections"], session_id="s", tool_call_id="c1"))
        assert result["error_count"] == 1 and wire == []


class TestDraftPolicy:
    def test_send_without_asking_sends_attended_turns_directly(self, bot_home, bot_chat):
        _write_config(bot_home, drafts="false")
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert owner.cards == []

    def test_a_profile_that_is_not_bot_mode_managed_is_untouched(self, bot_home, bot_chat):
        (bot_home / "profile.yaml").unlink()
        owner = _owner("deny")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert owner.cards == []
        assert bot_mode_draft_store.list_pending() == []

    def test_drafts_true_turns_them_on_for_an_unmanaged_profile(self, bot_home, bot_chat):
        (bot_home / "profile.yaml").unlink()
        _write_config(bot_home, drafts="true")
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert len(owner.cards) == 1

    @pytest.mark.parametrize("setting", [{}, {"drafts": "false"}])
    def test_unattended_runs_hold_the_draft_whatever_the_setting(self, bot_home, monkeypatch, setting):
        _write_config(bot_home, **setting)
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        owner = _owner("once")
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert args is None and "NOT sent" in block and owner.cards == []
        held = bot_mode_draft_store.list_pending()
        assert len(held) == 1 and held[0]["origin"] == "unattended" and held[0]["text"] == EMAIL_ARGS["body"]

    def test_a_turn_outside_the_bot_chat_holds_instead_of_rendering_a_card(self, bot_home):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, EMAIL_ARGS)
        assert "NOT sent" in block and owner.cards == []
        assert [d["origin"] for d in bot_mode_draft_store.list_pending()] == ["elsewhere"]

    def test_tools_that_send_nothing_never_touch_the_gate(self, bot_home, bot_chat):
        owner = _owner("deny")
        assert review_outbound("connectors__gmail__LIST_THREADS", {}) == (None, None)
        assert review_outbound("terminal", {"command": "ls"}) == (None, None)
        assert owner.cards == []


@pytest.fixture
def sent(monkeypatch):
    calls = []

    def fake(tool, args, **kwargs):
        calls.append((tool, args, kwargs))
        return json.dumps({"response": {"ok": True}})

    monkeypatch.setattr("model_tools.handle_function_call", fake)
    return calls


def _hold(origin="unattended", args=None):
    outbound = classify_outbound(EMAIL, args or EMAIL_ARGS)
    return bot_mode_draft_store.hold(outbound, args or EMAIL_ARGS, origin=origin)


class TestHeldDrafts:
    def test_pending_card_is_the_same_shape_a_live_approval_card_reads(self, bot_home):
        record = _hold()
        (card,) = bot_mode_draft_store.pending_cards()
        assert card["request_id"] == f"draft:{record['id']}"
        assert card["command"] == EMAIL_ARGS["body"] and card["choices"] == ["once", "deny"]
        assert card["draft"]["held"] is True and card["draft"]["state"] == "pending"
        assert card["draft"]["recipient"] == "ada@example.com"

    def test_send_delivers_the_stored_call_exactly_once(self, bot_home, sent):
        record = _hold()
        assert bot_mode_draft_store.send(record["id"]) == {"status": "sent"}
        assert [(t, a) for t, a, _ in sent] == [(EMAIL, EMAIL_ARGS)]
        assert sent[0][2]["skip_pre_tool_call_hook"] is True
        with pytest.raises(bot_mode_draft_store.DraftError) as again:
            bot_mode_draft_store.send(record["id"])
        assert again.value.code == "not_found" and len(sent) == 1
        assert bot_mode_draft_store.list_pending() == []

    def test_edit_then_send_delivers_the_edited_text(self, bot_home, sent):
        record = _hold()
        bot_mode_draft_store.send(record["id"], "Lunch at one?")
        assert sent[0][1] == {**EMAIL_ARGS, "body": "Lunch at one?"}

    def test_an_invalid_edit_sends_nothing_and_keeps_the_draft(self, bot_home, sent):
        record = _hold()
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"], "token ghp_" + "a" * 36)
        assert err.value.code == "invalid_edit" and sent == []
        assert [d["id"] for d in bot_mode_draft_store.list_pending()] == [record["id"]]

    def test_discard_is_final(self, bot_home, sent):
        record = _hold()
        bot_mode_draft_store.discard(record["id"])
        with pytest.raises(bot_mode_draft_store.DraftError):
            bot_mode_draft_store.send(record["id"])
        with pytest.raises(bot_mode_draft_store.DraftError):
            bot_mode_draft_store.discard(record["id"])
        assert sent == []

    def test_an_expired_draft_is_never_sent_by_anyone_but_can_be_discarded(self, bot_home, sent):
        _write_config(bot_home, draft_ttl_seconds=1)
        record = _hold()
        path = bot_home / "bot_mode" / "drafts" / "pending" / f"{record['id']}.json"
        stored = json.loads(path.read_text())
        stored["expires_at"] = stored["created_at"] - 5
        path.write_text(json.dumps(stored))
        (card,) = bot_mode_draft_store.pending_cards()
        assert card["draft"]["state"] == "expired" and card["choices"] == ["deny"]
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"])
        assert err.value.code == "expired" and sent == []
        bot_mode_draft_store.discard(record["id"])
        assert bot_mode_draft_store.list_pending() == []

    def test_a_failed_delivery_goes_back_to_pending_for_a_retry(self, bot_home, monkeypatch):
        monkeypatch.setattr("model_tools.handle_function_call",
                            lambda *a, **k: json.dumps({"error": {"code": "AUTH", "message": "expired token"}}))
        record = _hold()
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"])
        assert err.value.code == "send_failed"
        (still,) = bot_mode_draft_store.list_pending()
        assert still["id"] == record["id"] and still["last_error"] == "expired token"

    @pytest.mark.parametrize("bad", ["../../etc/passwd", "x", "", None, "A" * 32, "g" * 32])
    def test_ids_that_are_not_ours_are_refused(self, bot_home, sent, bad):
        for action in (bot_mode_draft_store.send, bot_mode_draft_store.discard):
            with pytest.raises(bot_mode_draft_store.DraftError):
                action(bad)
        assert sent == []

    def test_send_message_drafts_deliver_through_the_send_message_helper(self, bot_home, monkeypatch):
        args = {"action": "send", "target": "telegram:123", "message": "hello"}
        delivered = []
        monkeypatch.setattr("tools.send_message_tool.send_message_tool",
                            lambda a, **k: delivered.append(a) or json.dumps({"success": True}))
        outbound = classify_outbound("send_message", args)
        record = bot_mode_draft_store.hold(outbound, args, origin="unattended")
        bot_mode_draft_store.send(record["id"], "hello there")
        assert delivered == [{**args, "message": "hello there"}]

    def test_held_files_are_private_and_a_profile_only_sees_its_own(self, bot_home, tmp_path):
        record = _hold()
        path = bot_home / "bot_mode" / "drafts" / "pending" / f"{record['id']}.json"
        assert path.stat().st_mode & 0o077 == 0
        assert bot_mode_draft_store.list_pending(tmp_path / "another-profile") == []
        with pytest.raises(bot_mode_draft_store.DraftError):
            bot_mode_draft_store.discard(record["id"], tmp_path / "another-profile")


class TestSendMessageActionsMirrorTheTool:
    @pytest.mark.parametrize("action", [
        "send", "SEND", "Send", "post", "", None, "list ", "LIST", "React", "forward", "broadcast", 5,
    ])
    def test_every_action_the_tool_would_send_is_outbound(self, action):
        outbound = classify_outbound("send_message", {"action": action, "target": "telegram:1", "message": "hi"})
        assert outbound is not None

    @pytest.mark.parametrize("action", ["list", "react", "unreact"])
    def test_only_the_non_sending_actions_are_exempt(self, action):
        assert classify_outbound("send_message", {"action": action, "target": "telegram:1", "message": "hi"}) is None

    def test_the_gate_and_the_tool_agree_on_every_action(self, monkeypatch):
        import tools.send_message_tool as tool
        reached = []
        monkeypatch.setattr(tool, "_handle_send", lambda args: reached.append("send") or "{}")
        monkeypatch.setattr(tool, "_handle_list", lambda: reached.append("list") or "{}")
        monkeypatch.setattr(tool, "_handle_react", lambda args, remove=False: reached.append("react") or "{}")
        for action in ("send", "SEND", "post", "", None, "list", "LIST", " list", "react", "unreact", "React",
                       "Unreact", "delete", "edit"):
            reached.clear()
            args = {"action": action, "target": "telegram:1", "message": "hi"}
            tool.send_message_tool(args)
            assert (classify_outbound("send_message", args) is not None) == (reached == ["send"]), action

    def test_a_non_send_action_variant_is_drafted_not_sent(self, bot_home, bot_chat):
        owner = _owner("deny")
        block, _ = review_outbound("send_message", {"action": "post", "target": "telegram:1", "message": "hi"})
        assert "NOT sent" in block and len(owner.cards) == 1


@pytest.fixture
def attachment(tmp_path):
    path = tmp_path / "menu.pdf"
    path.write_bytes(b"x" * 2048)
    return path


class TestTheOwnerSeesEverythingThatIsSent:
    def _args(self, attachment):
        return {**EMAIL_ARGS, "cc": ["bob@example.com", "eve@example.com"], "bcc": "spy@example.com",
                "html_body": "<b>Lunch</b> at noon", "thread_id": "t-9",
                "attachments": [str(attachment), {"filename": "notes.txt", "content": "aGVsbG8="}]}

    def test_the_card_lists_every_other_argument_in_full(self, bot_home, bot_chat, attachment):
        owner = _owner("once")
        assert review_outbound(EMAIL, self._args(attachment)) == (None, None)
        shown = {item["name"]: item["value"] for item in owner.cards[0]["details"]}
        assert set(shown) == {"cc", "bcc", "html_body", "thread_id", "attachments"}
        assert "bob@example.com" in shown["cc"] and "eve@example.com" in shown["cc"]
        assert shown["bcc"] == "spy@example.com" and shown["html_body"] == "<b>Lunch</b> at noon"
        assert shown["thread_id"] == "t-9"
        assert "menu.pdf" in shown["attachments"] and "2.0 KB" in shown["attachments"]
        assert "notes.txt" in shown["attachments"]

    def test_the_description_the_cli_prompt_reads_carries_them_too(self, bot_home, bot_chat, attachment):
        owner = _owner("once")
        review_outbound(EMAIL, self._args(attachment))
        assert "bcc: spy@example.com" in owner.cards[0]["description"]

    def test_a_plain_send_has_no_extra_details(self, bot_home, bot_chat):
        owner = _owner("once")
        review_outbound(EMAIL, EMAIL_ARGS)
        assert owner.cards[0]["details"] == []

    def test_held_cards_list_them_as_well(self, bot_home, attachment):
        args = self._args(attachment)
        bot_mode_draft_store.hold(classify_outbound(EMAIL, args), args, origin="unattended")
        (card,) = bot_mode_draft_store.pending_cards()
        assert {item["name"] for item in card["details"]} == {"cc", "bcc", "html_body", "thread_id", "attachments"}
        assert "bcc: spy@example.com" in card["description"]

    @pytest.mark.parametrize("where", [
        {"bcc": "ghp_" + "a" * 36},
        {"cc": ["ok@example.com", "ghp_" + "b" * 36]},
        {"attachments": [{"filename": "a.txt", "note": "ghp_" + "c" * 36}]},
        {"metadata": {"deep": {"er": ["ghp_" + "d" * 36]}}},
    ])
    def test_a_secret_anywhere_in_the_arguments_is_refused_without_a_draft(self, bot_home, bot_chat, where):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, **where})
        assert "credential" in block and owner.cards == []
        assert bot_mode_draft_store.list_pending() == []

    def test_an_argument_that_cannot_be_shown_is_held_and_can_only_be_discarded(self, bot_home, bot_chat, sent):
        owner = _owner("once")
        args = {**EMAIL_ARGS, "score": float("nan")}
        block, edited = review_outbound(EMAIL, args)
        assert "NOT sent" in block and edited is None and owner.cards == []
        (record,) = bot_mode_draft_store.list_pending()
        (card,) = bot_mode_draft_store.pending_cards()
        assert card["choices"] == ["deny"] and card["draft"]["editable"] is False
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"])
        assert err.value.code == "unviewable" and sent == []
        bot_mode_draft_store.discard(record["id"])
        assert bot_mode_draft_store.list_pending() == []

    def test_oversized_arguments_are_refused_outright(self, bot_home, bot_chat):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, "html_body": "x" * 400_000})
        assert "too long" in block and owner.cards == []
        assert bot_mode_draft_store.list_pending() == []

    def test_an_edit_keeps_every_other_argument_as_the_owner_saw_it(self, bot_home, bot_chat, attachment):
        args = self._args(attachment)
        _owner(("once", "Lunch at one?"))
        block, edited = review_outbound(EMAIL, args)
        assert block is None and edited == {**args, "body": "Lunch at one?"}


class TestDiscardRaces:
    def test_a_discard_before_the_send_commits_means_nothing_is_delivered(self, bot_home, sent, monkeypatch):
        record = _hold()
        real = bot_mode_draft_store.classify_outbound

        def discard_first(tool, args):
            bot_mode_draft_store.discard(record["id"])
            return real(tool, args)

        monkeypatch.setattr(bot_mode_draft_store, "classify_outbound", discard_first)
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"])
        assert err.value.code == "discarded" and sent == []
        assert bot_mode_draft_store.list_pending() == []

    def test_a_send_that_fails_validation_never_restores_a_discarded_draft(self, bot_home, sent, monkeypatch):
        record = _hold()

        def discard_then_reject(outbound, args, edited):
            bot_mode_draft_store.discard(record["id"])
            return None, "the edit is bad"

        monkeypatch.setattr(bot_mode_draft_store, "validate_edit", discard_then_reject)
        with pytest.raises(bot_mode_draft_store.DraftError):
            bot_mode_draft_store.send(record["id"], "something else")
        assert bot_mode_draft_store.list_pending() == [] and sent == []

    def test_a_discard_after_the_provider_call_started_is_refused_not_pretended(self, bot_home, monkeypatch):
        record = _hold()
        seen = {}

        def deliver(tool, args, **kwargs):
            with pytest.raises(bot_mode_draft_store.DraftError) as err:
                bot_mode_draft_store.discard(record["id"])
            seen["code"] = err.value.code
            return json.dumps({"response": "ok"})

        monkeypatch.setattr("model_tools.handle_function_call", deliver)
        assert bot_mode_draft_store.send(record["id"]) == {"status": "sent"}
        assert seen["code"] == "sending" and bot_mode_draft_store.list_pending() == []

    def test_a_failed_send_that_could_not_be_discarded_stays_pending_for_the_owner(self, bot_home, monkeypatch):
        record = _hold()

        def fail(tool, args, **kwargs):
            with pytest.raises(bot_mode_draft_store.DraftError):
                bot_mode_draft_store.discard(record["id"])
            return json.dumps({"error": {"message": "provider down"}})

        monkeypatch.setattr("model_tools.handle_function_call", fail)
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            bot_mode_draft_store.send(record["id"])
        assert err.value.code == "send_failed"
        (still,) = bot_mode_draft_store.list_pending()
        assert still["id"] == record["id"] and still["last_error"] == "provider down"

    def test_discard_only_acts_on_what_is_still_pending(self, bot_home, sent):
        record = _hold()
        bot_mode_draft_store.send(record["id"])
        with pytest.raises(bot_mode_draft_store.DraftError):
            bot_mode_draft_store.discard(record["id"])

    def test_two_concurrent_sends_deliver_once(self, bot_home, monkeypatch):
        import threading
        record = _hold()
        delivered, gate, first_done = [], threading.Event(), threading.Event()

        def slow(tool, args, **kwargs):
            delivered.append(args)
            gate.wait(2)
            return json.dumps({"response": "ok"})

        monkeypatch.setattr("model_tools.handle_function_call", slow)
        outcomes = []

        def attempt():
            try:
                outcomes.append(bot_mode_draft_store.send(record["id"]))
            except bot_mode_draft_store.DraftError as exc:
                outcomes.append(exc.code)
                first_done.set()

        threads = [threading.Thread(target=attempt) for _ in range(2)]
        for thread in threads:
            thread.start()
        first_done.wait(5)
        gate.set()
        for thread in threads:
            thread.join(5)
        assert len(delivered) == 1 and sorted(map(str, outcomes)) == sorted(["not_found", str({"status": "sent"})])


class TestFailClosed:
    def test_a_classification_crash_blocks_a_send_shaped_tool(self, bot_home, bot_chat, monkeypatch):
        monkeypatch.setattr("tools.bot_mode_drafts.classify_outbound",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert "NOT sent" in block and args is None
        assert review_outbound("terminal", {"command": "ls"}) == (None, None)
        assert review_outbound("connectors__gmail__LIST_THREADS", {}) == (None, None)

    def test_a_crash_does_not_touch_a_profile_that_is_not_bot_managed(self, bot_home, bot_chat, monkeypatch):
        (bot_home / "profile.yaml").unlink()
        monkeypatch.setattr("tools.bot_mode_drafts.classify_outbound",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)

    def test_arguments_that_are_not_a_mapping_never_slip_past(self, bot_home, bot_chat):
        block, _ = review_outbound(EMAIL, "not a dict")
        assert "NOT sent" in block
        assert review_outbound("terminal", "not a dict") == (None, None)

    def test_a_crash_while_loading_or_resolving_hooks_blocks_a_send(self, bot_home, bot_chat):
        from types import SimpleNamespace

        from tools.bot_mode_drafts import review_after_hooks

        def boom(*_):
            raise RuntimeError("hook exploded")

        quiet = SimpleNamespace(modified_args=None)
        for load, resolve in ((boom, lambda details: None), (lambda: quiet, boom)):
            block, _ = review_after_hooks(EMAIL, dict(EMAIL_ARGS), load, resolve)
            assert "NOT sent" in block
            with pytest.raises(RuntimeError):
                review_after_hooks("terminal", {"command": "ls"}, load, resolve)

    def test_a_crash_inside_the_hook_dispatch_blocks_a_send(self, bot_home, bot_chat, monkeypatch):
        from hermes_cli import plugins
        monkeypatch.setattr(plugins, "_get_pre_tool_call_directive_details",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("plugin crash")))
        block, args = plugins._dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert "NOT sent" in block and args is None
        with pytest.raises(RuntimeError):
            plugins._dispatch_pre_tool_call_hooks("terminal", {"command": "ls"})

    def test_the_agent_loop_does_not_run_a_send_when_the_hook_dispatch_crashes(self, bot_home, bot_chat, monkeypatch):
        from types import SimpleNamespace

        from hermes_cli import plugins
        from agent import agent_runtime_helpers, tool_executor
        monkeypatch.setattr(plugins, "_dispatch_pre_tool_call_hooks",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("dispatch crash")))
        agent = SimpleNamespace(session_id="s")
        ref = tool_executor._ToolCallRef(name=EMAIL, args=dict(EMAIL_ARGS), task_id="t", call_id="c", trace=[])
        block, _ = tool_executor._pre_tool_block(agent, ref)
        assert block is not None and "NOT sent" in block
        other = tool_executor._ToolCallRef(name="terminal", args={"command": "ls"}, task_id="t", call_id="c", trace=[])
        assert tool_executor._pre_tool_block(agent, other)[0] is None
        block, _ = agent_runtime_helpers._pre_tool_block_message(agent, EMAIL, dict(EMAIL_ARGS), "t", "c", [])
        assert block is not None and "NOT sent" in block
        assert agent_runtime_helpers._pre_tool_block_message(agent, "terminal", {}, "t", "c", [])[0] is None


class TestSingleEditOnly:
    def test_resolve_all_never_hands_one_edit_to_every_draft(self, bot_home, bot_chat):
        import contextvars
        import threading
        cards, both_waiting, results = [], threading.Event(), []

        def notify(data):
            cards.append(data)
            if len(cards) == 2:
                both_waiting.set()

        approval.register_gateway_notify(SESSION, notify)

        def ask(index):
            results.append(approval.request_draft_approval(
                text=f"message {index}", description="d", pattern_key=f"k{index}",
                draft={"kind": "outbound_message", "text": f"message {index}"}))

        threads = [threading.Thread(target=contextvars.copy_context().run, args=(ask, i)) for i in range(2)]
        for thread in threads:
            thread.start()
        assert both_waiting.wait(5)
        assert approval.resolve_gateway_approval(SESSION, "once", resolve_all=True, edited_text="HIJACK") == 2
        for thread in threads:
            thread.join(5)
        assert len(results) == 2 and all(result["approved"] for result in results)
        assert all("edited_text" not in result for result in results)

    def test_an_edit_for_one_request_id_still_lands_on_that_draft_alone(self, bot_home, bot_chat):
        owner = _owner(("once", "edited"))
        outbound = classify_outbound(EMAIL, EMAIL_ARGS)
        from tools.bot_mode_drafts import _ask_owner
        block, args = _ask_owner(outbound, dict(EMAIL_ARGS))
        assert block is None and args == {**EMAIL_ARGS, "body": "edited"} and len(owner.cards) == 1


class TestPendingDraftCap:
    def test_new_drafts_are_refused_at_the_cap_with_a_clear_error(self, bot_home, monkeypatch):
        monkeypatch.setattr(bot_mode_draft_store, "MAX_PENDING_DRAFTS", 3)
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        for _ in range(3):
            assert "NOT sent" in review_outbound(EMAIL, EMAIL_ARGS)[0]
        assert len(bot_mode_draft_store.list_pending()) == 3
        block, _ = review_outbound(EMAIL, EMAIL_ARGS)
        assert "NOT sent" in block and "too many drafts" in block
        assert len(bot_mode_draft_store.list_pending()) == 3

    def test_discarding_frees_room_and_other_profiles_are_unaffected(self, bot_home, tmp_path, monkeypatch):
        monkeypatch.setattr(bot_mode_draft_store, "MAX_PENDING_DRAFTS", 2)
        first, _second = _hold(), _hold()
        with pytest.raises(bot_mode_draft_store.DraftError) as err:
            _hold()
        assert err.value.code == "limit"
        other = tmp_path / "another-profile"
        bot_mode_draft_store.hold(classify_outbound(EMAIL, EMAIL_ARGS), EMAIL_ARGS, origin="x", home=other)
        bot_mode_draft_store.discard(first["id"])
        assert _hold()["id"]
