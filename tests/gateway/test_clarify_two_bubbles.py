"""Every ask is two bubbles: the details as the bot's own message, then one short question card.

The split runs in ``stage_tool_call_message``'s helper before the tool-call row is persisted, and the
real ``_emit_interim_assistant_message`` runs inside a real gateway turn, so the order the owner sees
(details bubble, then the card with the short question) is what these assert, for any bot.
"""

from __future__ import annotations

import json

import pytest

from agent.agent_runtime_helpers import strip_think_blocks
from agent.stream_delivery import StreamDeliveryMixin
from agent.turn_tool_round import _split_clarify_details
from tests.gateway.test_run_progress_topics import _run_with_agent
from types import SimpleNamespace

QUIET = {"display": {"tool_progress": "off", "interim_assistant_messages": False}, "streaming": {"enabled": False}}
PROPOSAL = ("Job: https://example.test/job/1\nRate: $50/h, fee 10%\n\nCover letter:\nHi team, I can start Monday.\n\n"
            "Submit this proposal?")
ROWS: list[dict] = []


def _turn(content: str, question: str):
    arguments = json.dumps({"questions": [{"question": question, "choices": ["Approve", "Edit", "Cancel"]}]})
    call = SimpleNamespace(id="c1", function=SimpleNamespace(name="clarify", arguments=arguments))
    message = SimpleNamespace(tool_calls=[call], content=content)
    row = {"role": "assistant", "content": content, "tool_calls": [
        {"id": "c1", "type": "function", "function": {"name": "clarify", "arguments": arguments}}]}
    return message, row


class _StagingAgent(StreamDeliveryMixin):
    question = PROPOSAL
    content = ""
    _strip_think_blocks = strip_think_blocks

    def __init__(self, **kwargs):
        self.tools = []
        self.interim_assistant_callback = kwargs.get("interim_assistant_callback")

    def run_conversation(self, message, conversation_history=None, task_id=None):
        provider_message, row = _turn(type(self).content, type(self).question)
        _split_clarify_details(provider_message, row)
        ROWS.append(row)
        self._emit_interim_assistant_message(row)
        return {"final_response": "done", "messages": [row], "api_calls": 1}


@pytest.fixture(autouse=True)
def _clear_rows():
    ROWS.clear()


@pytest.mark.asyncio
async def test_details_reach_the_chat_before_the_card_and_the_card_holds_only_the_question(monkeypatch, tmp_path):
    adapter, _ = await _run_with_agent(monkeypatch, tmp_path, _StagingAgent, session_id="sess-two-bubbles", config_data=QUIET)

    assert len(adapter.sent) == 1
    details = adapter.sent[0]["content"]
    assert details.startswith("Job: https://example.test/job/1") and "Hi team, I can start Monday." in details
    assert "Submit this proposal?" not in details
    (row,) = ROWS
    card = json.loads(row["tool_calls"][0]["function"]["arguments"])["questions"][0]
    assert card == {"question": "Submit this proposal?", "choices": ["Approve", "Edit", "Cancel"]}
    assert row["content"] == details


@pytest.mark.asyncio
async def test_a_short_question_sends_no_extra_bubble(monkeypatch, tmp_path):
    monkeypatch.setattr(_StagingAgent, "question", "Submit this proposal?")
    adapter, _ = await _run_with_agent(monkeypatch, tmp_path, _StagingAgent, session_id="sess-short", config_data=QUIET)

    assert adapter.sent == []
    assert json.loads(ROWS[0]["tool_calls"][0]["function"]["arguments"])["questions"][0]["question"] == "Submit this proposal?"


@pytest.mark.asyncio
async def test_prose_the_bot_wrote_stays_first_then_the_details(monkeypatch, tmp_path):
    monkeypatch.setattr(_StagingAgent, "content", "Found a match.")
    adapter, _ = await _run_with_agent(monkeypatch, tmp_path, _StagingAgent, session_id="sess-prose", config_data=QUIET)

    assert [call["content"] for call in adapter.sent] == [ROWS[0]["content"]]
    assert ROWS[0]["content"].startswith("Found a match.\n\nJob: https://example.test/job/1")


def test_the_turn_loop_stage_applies_the_split_before_the_row_is_persisted():
    from unittest.mock import MagicMock

    from agent.turn_tool_round import stage_tool_call_message

    provider_message, row = _turn("", PROPOSAL)
    agent = MagicMock()
    agent._build_assistant_message.return_value = row
    messages: list = []

    staged, _ = stage_tool_call_message(agent, assistant_message=provider_message, finish_reason="tool_calls",
                                        messages=messages)

    assert staged is row and staged["content"].startswith("Job: https://example.test/job/1")
    assert json.loads(provider_message.tool_calls[0].function.arguments)["questions"][0]["question"] == "Submit this proposal?"
