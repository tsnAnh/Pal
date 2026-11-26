import json
import textwrap

import pytest

import hermes_cli.config as hc
from tools import approval, approval_context
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, classify_outbound, review_outbound

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
def owner_app():
    token = approval_context.set_approval_client_probe(lambda: True)
    yield
    approval_context.reset_approval_client_probe(token)


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


def _nothing_stored(home):
    return not (home / "bot_mode" / "drafts").exists()


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
        assert outbound.text.startswith("```json\n") and outbound.text.endswith("\n```")
        assert json.loads(outbound.text.removeprefix("```json\n").removesuffix("\n```")) == {"draft_id": "d1"}
        assert not outbound.editable


class TestAttendedDrafts:
    def test_send_runs_the_call_as_drafted(self, bot_home, owner_app):
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        card = owner.cards[0]
        assert card["choices"] == ["once", "deny"]
        assert card["command"] == EMAIL_ARGS["body"]
        assert card["draft"] == {"kind": "outbound_message", "channel": "Gmail", "recipient": "ada@example.com",
                                 "subject": "Lunch", "text": "Lunch at noon?", "editable": True, "held": False}
        assert card["choices"] == ["once", "deny"]

    def test_discard_is_final_within_the_turn_and_a_new_owner_message_clears_it(self, bot_home, owner_app):
        owner = _owner("deny", "once")
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert args is None and "NOT sent" in block and "Do NOT retry" in block
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert args is None and "NOT sent" in block and "next message" in block
        assert len(owner.cards) == 1
        assert _nothing_stored(bot_home)
        tokens = approval_context.set_current_observability_context(turn_id="turn-2")
        try:
            assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        finally:
            approval_context.reset_current_observability_context(tokens)
        assert len(owner.cards) == 2

    def test_a_discarded_draft_does_not_hold_a_different_recipient(self, bot_home, owner_app):
        owner = _owner("deny", "once")
        assert review_outbound(EMAIL, EMAIL_ARGS)[0] is not None
        assert review_outbound(EMAIL, {**EMAIL_ARGS, "to": "bob@example.com"}) == (None, None)
        assert len(owner.cards) == 2

    def test_edit_then_send_sends_the_edited_text(self, bot_home, owner_app):
        _owner(("once", "Lunch at one instead?"))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert block is None
        assert args == {**EMAIL_ARGS, "body": "Lunch at one instead?"}

    @pytest.mark.parametrize("edit", ["   ", "x" * 100_001, "token ghp_" + "a" * 36])
    def test_an_invalid_edit_is_revalidated_and_nothing_is_sent(self, bot_home, owner_app, edit):
        _owner(("once", edit))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert block is not None and args is None and "NOT sent" in block

    def test_an_edit_cannot_change_where_the_message_goes(self, bot_home):
        outbound = classify_outbound(EMAIL, EMAIL_ARGS)
        from tools.bot_mode_drafts import validate_edit
        assert validate_edit(outbound, EMAIL_ARGS, "new text")[0] == {**EMAIL_ARGS, "body": "new text"}
        assert validate_edit(classify_outbound("connectors__gmail__SEND_DRAFT", {"draft_id": "d"}),
                             {"draft_id": "d"}, "x")[0] is None

    def test_a_secret_in_the_body_is_refused_without_a_draft(self, bot_home, owner_app):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, "body": "key ghp_" + "a" * 36})
        assert "credential" in block and owner.cards == []
        assert _nothing_stored(bot_home)

    def test_no_answer_never_sends_and_stores_nothing(self, bot_home, owner_app):
        owner = _owner(None)
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert len(owner.cards) == 1 and _nothing_stored(bot_home)


class TestToolCallPipeline:
    def test_the_real_pre_tool_call_dispatch_applies_an_edited_send(self, bot_home, owner_app):
        from hermes_cli.plugins import _dispatch_pre_tool_call_hooks
        _owner(("once", "Lunch at one?"))
        block, args = _dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert block is None and args == {**EMAIL_ARGS, "body": "Lunch at one?"}

    def test_the_real_pre_tool_call_dispatch_blocks_a_discarded_send(self, bot_home, owner_app):
        from hermes_cli.plugins import _dispatch_pre_tool_call_hooks
        _owner("deny")
        block, args = _dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert "NOT sent" in block and args is None

    def test_a_connector_batch_entry_is_drafted_and_never_reaches_the_wire(self, bot_home, owner_app, monkeypatch):
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
    def test_send_without_asking_sends_attended_turns_directly(self, bot_home, owner_app):
        _write_config(bot_home, drafts="false")
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert owner.cards == []

    def test_a_profile_that_is_not_bot_mode_managed_is_untouched(self, bot_home, owner_app):
        (bot_home / "profile.yaml").unlink()
        owner = _owner("deny")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert owner.cards == []
        assert _nothing_stored(bot_home)

    def test_drafts_true_turns_them_on_for_an_unmanaged_profile(self, bot_home, owner_app):
        (bot_home / "profile.yaml").unlink()
        _write_config(bot_home, drafts="true")
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        assert len(owner.cards) == 1

    @pytest.mark.parametrize("setting", [{}, {"drafts": "false"}])
    def test_unattended_runs_refuse_the_send_whatever_the_setting(self, bot_home, monkeypatch, setting):
        _write_config(bot_home, **setting)
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and _nothing_stored(bot_home)

    def test_a_turn_outside_the_owner_app_refuses_instead_of_rendering_a_card(self, bot_home):
        owner = _owner("once")
        assert review_outbound(EMAIL, EMAIL_ARGS) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and _nothing_stored(bot_home)

    def test_tools_that_send_nothing_never_touch_the_gate(self, bot_home, owner_app):
        owner = _owner("deny")
        assert review_outbound("connectors__gmail__LIST_THREADS", {}) == (None, None)
        assert review_outbound("terminal", {"command": "ls"}) == (None, None)
        assert owner.cards == []


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
        import gateway.outbound.send as tool
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

    def test_a_non_send_action_variant_is_drafted_not_sent(self, bot_home, owner_app):
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

    def test_the_card_lists_every_other_argument_in_full(self, bot_home, owner_app, attachment):
        owner = _owner("once")
        assert review_outbound(EMAIL, self._args(attachment)) == (None, None)
        shown = {item["name"]: item["value"] for item in owner.cards[0]["details"]}
        assert set(shown) == {"cc", "bcc", "html_body", "thread_id", "attachments"}
        assert "bob@example.com" in shown["cc"] and "eve@example.com" in shown["cc"]
        assert shown["bcc"] == "spy@example.com" and shown["html_body"] == "<b>Lunch</b> at noon"
        assert shown["thread_id"] == "t-9"
        assert "menu.pdf" in shown["attachments"] and "2.0 KB" in shown["attachments"]
        assert "notes.txt" in shown["attachments"]

    def test_the_description_the_cli_prompt_reads_carries_them_too(self, bot_home, owner_app, attachment):
        owner = _owner("once")
        review_outbound(EMAIL, self._args(attachment))
        assert "bcc: spy@example.com" in owner.cards[0]["description"]

    def test_a_plain_send_has_no_extra_details(self, bot_home, owner_app):
        owner = _owner("once")
        review_outbound(EMAIL, EMAIL_ARGS)
        assert owner.cards[0]["details"] == []

    @pytest.mark.parametrize("where", [
        {"bcc": "ghp_" + "a" * 36},
        {"cc": ["ok@example.com", "ghp_" + "b" * 36]},
        {"attachments": [{"filename": "a.txt", "note": "ghp_" + "c" * 36}]},
        {"metadata": {"deep": {"er": ["ghp_" + "d" * 36]}}},
    ])
    def test_a_secret_anywhere_in_the_arguments_is_refused_without_a_draft(self, bot_home, owner_app, where):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, **where})
        assert "credential" in block and owner.cards == []
        assert _nothing_stored(bot_home)

    def test_an_argument_that_cannot_be_shown_is_refused_and_stores_nothing(self, bot_home, owner_app):
        owner = _owner("once")
        args = {**EMAIL_ARGS, "score": float("nan")}
        assert review_outbound(EMAIL, args) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and _nothing_stored(bot_home)

    def test_oversized_arguments_are_refused_outright(self, bot_home, owner_app):
        owner = _owner("once")
        block, _ = review_outbound(EMAIL, {**EMAIL_ARGS, "html_body": "x" * 400_000})
        assert "too long" in block and owner.cards == []
        assert _nothing_stored(bot_home)

    def test_an_edit_keeps_every_other_argument_as_the_owner_saw_it(self, bot_home, owner_app, attachment):
        args = self._args(attachment)
        _owner(("once", "Lunch at one?"))
        block, edited = review_outbound(EMAIL, args)
        assert block is None and edited == {**args, "body": "Lunch at one?"}


class TestFailClosed:
    def test_a_classification_crash_blocks_a_send_shaped_tool(self, bot_home, owner_app, monkeypatch):
        monkeypatch.setattr("tools.bot_mode_drafts.classify_outbound",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
        block, args = review_outbound(EMAIL, EMAIL_ARGS)
        assert "NOT sent" in block and args is None
        assert review_outbound("terminal", {"command": "ls"}) == (None, None)
        assert review_outbound("connectors__gmail__LIST_THREADS", {}) == (None, None)

    def test_a_crash_does_not_touch_a_profile_that_is_not_bot_managed(self, bot_home, owner_app, monkeypatch):
        (bot_home / "profile.yaml").unlink()
        monkeypatch.setattr("tools.bot_mode_drafts.classify_outbound",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
        assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)

    def test_arguments_that_are_not_a_mapping_never_slip_past(self, bot_home, owner_app):
        block, _ = review_outbound(EMAIL, "not a dict")
        assert "NOT sent" in block
        assert review_outbound("terminal", "not a dict") == (None, None)

    def test_a_crash_while_loading_or_resolving_hooks_blocks_a_send(self, bot_home, owner_app):
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

    def test_a_crash_inside_the_hook_dispatch_blocks_a_send(self, bot_home, owner_app, monkeypatch):
        from hermes_cli import plugins
        monkeypatch.setattr(plugins, "_get_pre_tool_call_directive_details",
                            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("plugin crash")))
        block, args = plugins._dispatch_pre_tool_call_hooks(EMAIL, dict(EMAIL_ARGS))
        assert "NOT sent" in block and args is None
        with pytest.raises(RuntimeError):
            plugins._dispatch_pre_tool_call_hooks("terminal", {"command": "ls"})

    def test_the_agent_loop_does_not_run_a_send_when_the_hook_dispatch_crashes(self, bot_home, owner_app, monkeypatch):
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
    def test_resolve_all_never_hands_one_edit_to_every_draft(self, bot_home, owner_app):
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

    def test_an_edit_for_one_request_id_still_lands_on_that_draft_alone(self, bot_home, owner_app):
        owner = _owner(("once", "edited"))
        outbound = classify_outbound(EMAIL, EMAIL_ARGS)
        from tools.bot_mode_drafts import _ask_owner
        block, args = _ask_owner(outbound, dict(EMAIL_ARGS))
        assert block is None and args == {**EMAIL_ARGS, "body": "edited"} and len(owner.cards) == 1


CONSUMERS = [
    ("mcp__upwork__upwork__send_message", {"action": "send", "recipient": "client-1", "message": "Hello"}),
    ("mcp__fakeconn__fakeconn__send_message", {"to": "ada", "message": "Hello"}),
    ("connectors__slack__SEND_MESSAGE", {"channel": "C1", "text": "Hello"}),
    ("connectors__gmail__SEND_EMAIL", EMAIL_ARGS),
    ("mcp__discord__post_message", {"channel_id": "9", "content": "Hello"}),
    ("send_message", {"action": "send", "target": "telegram:123", "message": "Hello"}),
]


class TestAnyChatOfTheBot:
    @pytest.mark.parametrize(("tool", "args"), CONSUMERS)
    def test_a_client_that_can_answer_gets_the_card_whatever_the_chat_is_called(self, bot_home, owner_app, tool, args):
        owner = _owner("once")
        assert review_outbound(tool, args) == (None, None)
        card = owner.cards[0]
        assert card["choices"] == ["once", "deny"] and "draft" in card
        assert card["command"] == args.get("message") or card["command"] == args.get("text") \
            or card["command"] == args.get("body") or card["command"] == args.get("content")
        assert _nothing_stored(bot_home)

    @pytest.mark.parametrize(("tool", "args"), CONSUMERS)
    def test_with_nobody_to_answer_every_consumer_is_refused_and_nothing_is_stored(self, bot_home, tool, args):
        owner = _owner("once")
        assert review_outbound(tool, args) == (NOT_SENT_NOBODY_TO_ASK, None)
        assert owner.cards == [] and _nothing_stored(bot_home)

    @pytest.mark.parametrize("setup", ["cron", "timeout", "unviewable", "no_client"])
    def test_every_refusal_reason_returns_the_one_message_and_stores_nothing(self, bot_home, monkeypatch, setup):
        args = EMAIL_ARGS
        if setup == "cron":
            monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        if setup == "timeout":
            _write_config(bot_home)
            token = approval_context.set_approval_client_probe(lambda: True)
            _owner(None)
        if setup == "unviewable":
            args = {**EMAIL_ARGS, "score": float("nan")}
            token = approval_context.set_approval_client_probe(lambda: True)
        try:
            assert review_outbound(EMAIL, args) == (NOT_SENT_NOBODY_TO_ASK, None)
        finally:
            if setup in ("timeout", "unviewable"):
                approval_context.reset_approval_client_probe(token)
        assert _nothing_stored(bot_home)

    def test_the_client_probe_is_read_when_the_question_is_asked_not_when_the_turn_began(self, bot_home):
        attached = {"now": False}
        token = approval_context.set_approval_client_probe(lambda: attached["now"])
        try:
            _owner("once")
            assert review_outbound(EMAIL, EMAIL_ARGS)[0] is not None
            attached["now"] = True
            assert review_outbound(EMAIL, EMAIL_ARGS) == (None, None)
        finally:
            approval_context.reset_approval_client_probe(token)

    @pytest.mark.parametrize("answer", ["always", "session"])
    def test_no_answer_becomes_a_standing_grant_every_send_is_its_own_card(self, bot_home, owner_app, answer):
        owner = _owner(answer, answer)
        for _ in range(2):
            review_outbound(EMAIL, EMAIL_ARGS)
        assert len(owner.cards) == 2
        assert all(card["choices"] == ["once", "deny"] for card in owner.cards)
        assert "plugin_rule" not in str(hc.load_config().get("command_allowlist", []))

    def test_the_secret_and_too_long_blocks_come_before_any_card_or_draft(self, bot_home, owner_app):
        owner = _owner("once")
        assert "credential" in review_outbound(EMAIL, {**EMAIL_ARGS, "body": "k ghp_" + "a" * 36})[0]
        assert "too long" in review_outbound(EMAIL, {**EMAIL_ARGS, "body": "x" * 100_001})[0]
        assert owner.cards == [] and _nothing_stored(bot_home)
