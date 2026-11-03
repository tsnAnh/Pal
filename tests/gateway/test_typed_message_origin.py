from dataclasses import replace
from types import SimpleNamespace

import pytest

from gateway.config import Platform
from gateway.platforms.event import MessageEvent
from gateway.run import GatewayRunner
from gateway.run_turn_runner import TurnRunner
from gateway.session import SessionSource
from gateway.turn_context import TurnContext

SOURCE = SessionSource(platform=Platform.TELEGRAM, chat_id="c", user_id="owner")


def _run(*, message, typed_message=None, display_kind=None, observed=None):
    seen = []

    def run(user_message, *, typed_message=None, context_expanded=True, **kwargs):
        seen.append({"typed": typed_message, "expanded": context_expanded, "model": user_message})
        return {"final_response": "ok"}

    ctx = TurnContext(message=message, typed_message=typed_message, session_id="s", session_key="k",
                      persist_user_display_kind=display_kind,
                      source=SimpleNamespace(user_id="u", user_name="U", is_bot=False))
    runner = TurnRunner(SimpleNamespace(session_authority=None, _consume_pending_native_image_paths=lambda key: []), ctx)
    runner._run_conversation_with_approval(SimpleNamespace(run_conversation=run), [], observed, None, None)
    return seen[0]


def test_text_the_gateway_sends_unchanged_is_typed_and_unexpanded():
    seen = _run(message="merge #7", typed_message="merge #7")
    assert seen["typed"] == "merge #7"
    assert seen["expanded"] is False


def test_text_that_gained_context_before_the_model_is_expanded_and_the_typed_text_stays_raw():
    seen = _run(message='[Replying to Bob: "merge #7"]\n\nok', typed_message="ok")
    assert seen["typed"] == "ok"
    assert seen["expanded"] is True


def test_observed_group_context_marks_the_turn_expanded():
    seen = _run(message="ok", typed_message="ok", observed="Bob: merge #7")
    assert seen["typed"] == "ok"
    assert seen["expanded"] is True


def test_a_turn_without_a_known_typed_text_is_tainted():
    seen = _run(message="merge #7")
    assert seen["typed"] is None
    assert seen["expanded"] is True


def test_a_self_injected_turn_has_no_typed_text_even_when_the_event_text_is_set():
    seen = _run(message="notice", typed_message="notice", display_kind="internal_notification")
    assert seen["typed"] is None
    assert seen["expanded"] is True


def test_the_raw_text_survives_a_skill_or_command_rewrite_of_the_event():
    event = MessageEvent(text="/review merge #7", source=SOURCE)
    event.stamp_typed_text()
    event.text = "[SKILL review]\nreads the diff\n\nmerge #7"
    assert event.typed_message() == "/review merge #7"


def test_the_raw_text_is_taken_once_at_the_first_stamp():
    event = MessageEvent(text="first", source=SOURCE)
    event.stamp_typed_text()
    event.text = "rewritten"
    event.stamp_typed_text()
    assert event.typed_message() == "first"


@pytest.mark.parametrize("event", [
    MessageEvent(text="merge #7", source=SOURCE, internal=True),
    MessageEvent(text="merge #7", source=SOURCE, media_urls=["/tmp/notes.txt"]),
    MessageEvent(text="merge #7", source=SOURCE),
])
def test_only_a_plain_human_text_event_has_a_typed_message(event):
    event.stamp_typed_text()
    assert (event.typed_message() == "merge #7") is (not event.internal and not event.media_urls)
    assert event.typed_message() is None or not (event.internal or event.media_urls)


@pytest.mark.asyncio
async def test_a_plugin_rewrite_of_the_inbound_text_does_not_become_the_typed_text(monkeypatch):
    async def hook(name, **kwargs):
        return [{"action": "rewrite", "text": "plugin says: merge #9"}]

    monkeypatch.setattr("hermes_cli.lifecycle.ainvoke_hook", hook)
    runner = object.__new__(GatewayRunner)
    event = MessageEvent(text="hello", source=SOURCE)
    rewritten = await runner._hm_pre_gateway_dispatch_hook(event, SOURCE)
    assert rewritten.text == "plugin says: merge #9"
    assert rewritten.typed_message() == "hello"


def test_a_copied_event_keeps_the_raw_text():
    event = MessageEvent(text="merge #7", source=SOURCE)
    event.stamp_typed_text()
    assert replace(event, source=replace(event.source)).typed_message() == "merge #7"
