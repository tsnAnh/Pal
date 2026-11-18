"""A bot's answer to a message_agent delivery reaches the sender's wake whole and as plain labelled lines."""

import json
from types import SimpleNamespace

import pytest

from gateway.run_notifications import GatewayNotificationsMixin
from tools.bot_mode_dm import MESSAGE_MAX_CHARS, REPLY_COMPLETION_CHARS
from tools.process_registry_notifications import format_process_notification

DELIVERY = "python /app/tools/bot_mode_dm.py --run-delivery stdin /tmp/hermes-dm/x.json hermes -p alice chat"


def _wake(output: str, command: str = DELIVERY, completion_output_chars: int = REPLY_COMPLETION_CHARS) -> str:
    session = SimpleNamespace(output_buffer=output, command=command, exit_code=0, task_id="", owner_task_id="",
                              started_at=1.0, parent_session_id="", completion_output_chars=completion_output_chars)
    event = GatewayNotificationsMixin._build_process_completion_event({}, session, "proc_abc123abc123")
    return format_process_notification(event)


def _receipt(reply: str, **fields) -> str:
    return json.dumps({"outcome": "@alice answered.", "reply": reply, "status": "settled", "delivery_id": "d" * 64,
                       **fields}) + "\n"


@pytest.mark.parametrize("size", [5000, 14000])
def test_a_reply_arrives_in_the_wake_whole_as_plain_lines(size):
    reply = ("word " * size)[:size]
    wake = _wake(_receipt(reply))

    assert reply in wake
    assert "Outcome: @alice answered.\nStatus: settled\nDelivery id: " + "d" * 64 in wake
    assert '"reply"' not in wake and "output truncated" not in wake


def test_a_reply_over_the_message_cap_is_cut_at_the_cap_and_says_so():
    wake = _wake(_receipt("x" * (MESSAGE_MAX_CHARS + 4000)))

    assert "x" * MESSAGE_MAX_CHARS in wake and "x" * (MESSAGE_MAX_CHARS + 1) not in wake
    assert "Reply (last 4000 characters cut):" in wake


def test_a_failed_delivery_keeps_its_reason_in_the_wake():
    wake = _wake(json.dumps({"reason": "runtime_unavailable", "error": "No canonical Bot Chat authority."}))

    assert "Reason: runtime_unavailable\nError: No canonical Bot Chat authority." in wake


def test_another_command_keeps_the_sized_tail_and_the_default_cap():
    sized = _wake("tail " * 1000, command="make build", completion_output_chars=3000)
    default = _wake("tail " * 1000, command="make build", completion_output_chars=0)

    assert "showing last" in sized and "showing last" in default
    assert len(sized) > len(default)
