"""A background process whose whole output is one line longer than the notification cap (a bot-to-bot
delivery's JSON receipt carrying a long reply) must reach the sender cut, never as zero characters."""

import json
from types import SimpleNamespace

import pytest

from gateway.run_notifications import GatewayNotificationsMixin
from tools.process_registry_notifications import format_process_notification


def _completion(output: str) -> dict:
    session = SimpleNamespace(output_buffer=output, command="python tools/bot_mode_dm.py --run-delivery", exit_code=0,
                              task_id="", owner_task_id="", started_at=1.0, parent_session_id="")
    return GatewayNotificationsMixin._build_process_completion_event({}, session, "proc_abc123abc123")


def _receipt(reply: str) -> str:
    return json.dumps({"outcome": "@bot answered.", "reply": reply, "status": "settled", "delivery_id": "d" * 64}) + "\n"


@pytest.mark.parametrize("reply", ["long reply " * 400, "# Report\n\n- **a** `code`\n```py\nx = 1\n```\n" * 120],
                         ids=["plain", "markdown"])
def test_a_receipt_over_the_cap_keeps_its_tail_and_never_reads_as_zero_chars(reply):
    event = _completion(_receipt(reply))
    message = format_process_notification(event)

    assert "showing last 0 chars" not in message
    assert '"status": "settled"' in event["output"] and "d" * 64 in event["output"]
    assert "output truncated" in event["output"]


def test_a_multi_line_output_still_snaps_to_a_line_boundary():
    lines = "".join(f"line {i:04d}\n" for i in range(400))
    output = _completion(lines)["output"]

    assert output.splitlines()[1].startswith("line ")
