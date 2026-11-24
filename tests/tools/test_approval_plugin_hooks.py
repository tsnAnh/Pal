"""Tests for pre_approval_request / post_approval_response plugin hooks.

These hooks fire in tools/approval.py::request_draft_approval and in elicitation consent whenever the owner
is asked. They are observer-only (return values ignored) and must fire on BOTH the CLI-interactive path and
the async gateway path, so external tools like macOS notifiers can be alerted regardless of which surface the
owner is on.
"""
from unittest.mock import patch

import pytest

import tools.approval as approval_module
from tools import approval_context
from tools.approval import clear_session, request_draft_approval
from tools.approval_context import set_current_session_key
from tools.approval_prompt import request_elicitation_consent

DRAFT = "Dinner at 7?"


def _ask(approval_callback=None):
    return request_draft_approval(text=DRAFT, description="Send a message", pattern_key="draft:hooks",
                                  draft={"kind": "message"}, approval_callback=approval_callback)


@pytest.fixture
def isolated_session(monkeypatch):
    session_key = "test:session:approval_hooks"
    token = set_current_session_key(session_key)
    monkeypatch.setenv("HERMES_SESSION_KEY", session_key)
    monkeypatch.setattr("tools.details_bubble.post_details", lambda *a, **k: None)
    try:
        yield session_key
    finally:
        try:
            approval_context._approval_session_key.reset(token)
        except Exception:
            pass
        clear_session(session_key)


class TestCliPathFiresHooks:
    """CLI-interactive approval path: HERMES_INTERACTIVE is set, the
    prompt_dangerous_approval() result decides the outcome."""

    @pytest.fixture(autouse=True)
    def _cli(self, monkeypatch):
        monkeypatch.setenv("HERMES_INTERACTIVE", "1")
        for name in ("HERMES_GATEWAY_SESSION", "HERMES_EXEC_ASK", "HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM"):
            monkeypatch.delenv(name, raising=False)

    def test_pre_and_post_fire_with_expected_kwargs(self, isolated_session):
        captured = []

        def fake_invoke_hook(hook_name, **kwargs):
            captured.append((hook_name, kwargs))
            return []

        with patch("hermes_cli.plugins.invoke_hook", side_effect=fake_invoke_hook):
            result = _ask(approval_callback=lambda command, description, **kw: "once")

        assert result["approved"] is True
        hook_names = [c[0] for c in captured]
        assert "pre_approval_request" in hook_names and "post_approval_response" in hook_names

        pre_kwargs = next(kw for name, kw in captured if name == "pre_approval_request")
        assert pre_kwargs["command"] == DRAFT
        assert pre_kwargs["surface"] == "cli"
        assert pre_kwargs["session_key"] == isolated_session
        assert pre_kwargs["pattern_keys"] == ["draft:hooks"] and pre_kwargs["pattern_key"] == "draft:hooks"
        assert pre_kwargs["description"]

        post_kwargs = next(kw for name, kw in captured if name == "post_approval_response")
        assert post_kwargs["choice"] == "once"
        assert post_kwargs["surface"] == "cli"
        assert post_kwargs["command"] == DRAFT

    def test_deny_reported_to_post_hook(self, isolated_session):
        captured = []

        def fake_invoke_hook(hook_name, **kwargs):
            captured.append((hook_name, kwargs))
            return []

        with patch("hermes_cli.plugins.invoke_hook", side_effect=fake_invoke_hook):
            result = _ask(approval_callback=lambda command, description, **kw: "deny")

        assert result["approved"] is False
        post_kwargs = next(kw for name, kw in captured if name == "post_approval_response")
        assert post_kwargs["choice"] == "deny"

    def test_plugin_hook_crash_does_not_break_approval(self, isolated_session):
        """A crashing plugin must never prevent the approval flow from reaching the user."""

        def boom(hook_name, **kwargs):
            raise RuntimeError("plugin crashed")

        with patch("hermes_cli.plugins.invoke_hook", side_effect=boom):
            result = _ask(approval_callback=lambda command, description, **kw: "once")

        assert result["approved"] is True


def _capture_hooks(run):
    """Run ``run()`` with the approval hook dispatch captured; drop the per-turn ids
    every surface adds, so only the prompt payload is compared."""
    captured = []
    with patch("hermes_cli.plugins.invoke_hook",
               side_effect=lambda name, **kw: captured.append((name, kw)) or []):
        result = run()
    # on_human_input_* fire around the same prompts with their own payload contract
    # (tests/tools/test_human_input_hooks.py); this helper compares the approval pair.
    captured = [(name, kw) for name, kw in captured if not name.startswith("on_human_input_")]
    for _, kw in captured:
        for key in ("turn_id", "tool_call_id", "session_id"):
            kw.pop(key, None)
    return result, captured


class TestClassicCliPromptsFireGatewayTwinHooks:
    """The elicitation consent prompt fires the same pre/post observer hooks in the classic CLI as its
    gateway twin (#131876)."""

    def test_cli_branch_fires_the_gateway_payload(self, isolated_session, monkeypatch):
        from tools.terminal_tool import set_approval_callback

        def run():
            return request_elicitation_consent("Allow server access?", "an MCP server asks",
                                               surface="mcp-trust/test-server")

        monkeypatch.setattr(approval_context, "_get_approval_config", lambda: {"timeout": 60})
        # Gateway twin: the notifier answers "once" as soon as the card is sent.
        monkeypatch.setenv("HERMES_GATEWAY_SESSION", "1")
        approval_module.register_gateway_notify(
            isolated_session, lambda _data: approval_module.resolve_gateway_approval(isolated_session, "once"))
        try:
            result, gateway_hooks = _capture_hooks(run)
        finally:
            approval_module.unregister_gateway_notify(isolated_session)
        assert result == "accept"

        # Classic CLI: the prompt_toolkit panel callback registered on the agent thread answers "once".
        monkeypatch.delenv("HERMES_GATEWAY_SESSION")
        set_approval_callback(lambda *_a, **_kw: "once")
        try:
            result, cli_hooks = _capture_hooks(run)
        finally:
            set_approval_callback(None)

        assert result == "accept"
        assert [name for name, _ in cli_hooks] == ["pre_approval_request", "post_approval_response"]
        expected = [(name, {**kw, "surface": "mcp-trust/test-server"}) for name, kw in gateway_hooks]
        assert cli_hooks == expected
