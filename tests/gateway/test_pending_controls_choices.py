import threading

from gateway.session_pending_controls import PendingControls


class _Events:
    def __init__(self):
        self.lock = threading.RLock()
        self.published = []

    def publish(self, session_id, payload, event_type):
        self.published.append((event_type, payload))


def test_an_approval_prompt_offers_once_or_deny_and_carries_the_question():
    events = _Events()
    controls = PendingControls(events)

    controls.register("sid", "route", 1, {
        "request_id": "draft-1", "command": "", "description": "Send to Ada",
        "question": "Send this message?", "allow_session": True, "allow_permanent": True})

    (event_type, prompt), = events.published
    assert event_type == "approval.request"
    assert prompt["choices"] == ["once", "deny"]
    assert prompt["question"] == "Send this message?"


def test_a_held_draft_prompt_keeps_its_draft_and_details():
    events = _Events()
    controls = PendingControls(events)
    draft = {"id": "d1", "kind": "message"}
    details = [{"label": "To", "value": "Ada"}]

    controls.register("sid", "route", 1, {
        "request_id": "draft:d1", "command": "Hi Ada", "description": "Send to Ada",
        "question": "Send this message?", "draft": draft, "details": details})

    (_, prompt), = events.published
    assert prompt["draft"] == draft
    assert prompt["details"] == details
