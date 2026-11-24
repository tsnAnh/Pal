"""Only a row written by ``session.submit`` counts as the session viewer's own input."""

import pytest


@pytest.mark.parametrize("request_id,payload,viewer", [
    ("typed", {"text": "hi", "cli_turn_v1": {"api_text": "[voice] hi"}, "finite": True}, True),
    ("typed", {"text": "hi", "local_operator_v1": {"principal_id": "op"}}, True),
    ('["plugin","desk","route","x"]', {"text": "hi", "local_automation_v1": {"identity": "x"}}, False),
    ('hosted:[{"task":1},0]', {"text": "room task"}, False),
    ("native", {"text": "hi", "native_text_v1": {"source": {}}}, False),
], ids=["cli-submit", "operator-submit", "automation", "hosted-room-task", "messaging"])
def test_viewer_input_is_only_a_session_submit_row(request_id, payload, viewer):
    from gateway.session_operator import is_viewer_input
    assert is_viewer_input({"request_id": request_id, "payload": payload}) is viewer
