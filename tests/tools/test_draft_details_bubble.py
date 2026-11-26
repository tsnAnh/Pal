"""An outbound-draft ask posts the draft's exact content as a bubble before its card is raised."""

import pytest

from agent.stream_delivery import StreamDeliveryMixin
from tools import approval
from tools.details_bubble import bound_details_sink, post_details


@pytest.fixture
def gateway_ask(monkeypatch):
    events: list = []
    monkeypatch.setattr(approval, "_presence", lambda cb=None: (cb, False, True, False))
    monkeypatch.setattr(
        approval, "_human_decision",
        lambda *_a, **kw: events.append(("card", kw["command"], kw["description"])) or {"approved": True})
    return events


def _ask():
    return approval.request_draft_approval(
        text="Lunch at noon?", description="Send to ada@example.com via email\nsubject: Lunch",
        pattern_key="outbound_draft:email:x", draft={"kind": "outbound_message"})


def test_details_bubble_comes_before_the_card_and_the_card_wire_is_unchanged(gateway_ask):
    sink_events = gateway_ask
    with bound_details_sink(lambda text: sink_events.append(("bubble", text)) or True):
        _ask()

    assert [kind for kind, *_ in sink_events] == ["bubble", "card"]
    assert sink_events[0][1] == "Send to ada@example.com via email\nsubject: Lunch\n\nLunch at noon?"
    assert sink_events[1][1:] == ("Lunch at noon?", "Send to ada@example.com via email\nsubject: Lunch")


def test_without_a_sink_the_card_is_raised_as_before(gateway_ask):
    assert _ask() == {"approved": True}
    assert [kind for kind, *_ in gateway_ask] == ["card"]


def test_a_cli_prompt_shows_the_draft_itself_so_no_bubble_is_posted(gateway_ask, monkeypatch):
    monkeypatch.setattr(approval, "_presence", lambda cb=None: (cb, True, False, False))
    posted: list = []
    with bound_details_sink(lambda text: posted.append(text) or True):
        _ask()
    assert posted == []


def test_blank_text_posts_nothing():
    with bound_details_sink(lambda text: pytest.fail("posted")):
        assert post_details("  \n") is False


class _Agent(StreamDeliveryMixin):
    def __init__(self, **callbacks):
        self.interim_assistant_callback = callbacks.get("interim")
        self.clarify_context_callback = callbacks.get("context")
        self._hold_stream = callbacks.get("hold", False)


def test_the_agent_sink_prefers_interim_then_clarify_context_and_reports_a_miss():
    shown: list = []
    assert _Agent(interim=lambda text, **_k: shown.append(("interim", text)))._deliver_details_bubble("a") is True
    assert _Agent(context=lambda text, **_k: shown.append(("context", text)))._deliver_details_bubble("b") is True
    assert shown == [("interim", "a"), ("context", "b")]
    assert _Agent()._deliver_details_bubble("c") is False
    assert _Agent(interim=lambda *_a, **_k: shown.append("held"), hold=True)._deliver_details_bubble("d") is False
    assert "held" not in shown


def test_a_failing_sink_reports_no_bubble_so_the_card_keeps_the_content():
    def boom(*_a, **_k):
        raise RuntimeError("no surface")
    assert _Agent(interim=boom)._deliver_details_bubble("e") is False
