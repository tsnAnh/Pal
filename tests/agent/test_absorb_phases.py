"""``AIAgent.absorb``: the owner wrote mid-turn. What the agent does depends on what the turn is doing,
and the text always reaches the model as its own user row after the newest tool result."""
import json
import threading

import pytest

from agent.interrupt_control import InterruptControlMixin
from agent.steer_absorb import deliver_steer_row
from tools import interrupt as interrupt_mod
from tools.interrupt import YieldReason


class Agent(InterruptControlMixin):
    api_mode = "chat_completions"

    def __init__(self, *, executing_tools=False, model_active=False, streamed=(), api_calls=3):
        self._pending_steer = None
        self._pending_steer_lock = threading.Lock()
        self._pending_redirect = None
        self._pending_redirect_lock = threading.Lock()
        self._interrupt_requested = False
        self._interrupt_message = None
        self._tool_interrupt_reason = None
        self._execution_thread_id = None
        self._interrupt_thread_signal_pending = False
        self._turn_user_intervened = False
        self._hard_interrupt_requested = threading.Event()
        self._executing_tools = executing_tools
        self._model_request_active = threading.Event()
        if model_active:
            self._model_request_active.set()
        self._streamed_assistant_text_parts = list(streamed)
        self._api_call_count = api_calls
        self._tool_worker_threads = {1001, 1002}
        self._tool_worker_threads_lock = threading.Lock()
        self.absorbed = []
        self.input_absorbed_callback = lambda **event: self.absorbed.append(event)


@pytest.fixture(autouse=True)
def _clean_yield_bits():
    yield
    for tid in (1001, 1002):
        interrupt_mod.take_yield(tid)


def test_absorbing_while_tools_run_steers_and_asks_every_worker_to_yield_for_the_owner():
    agent = Agent(executing_tools=True)
    assert agent.absorb("also check the other repo", ticket="adm_1") is True
    assert agent._pending_steer == "also check the other repo"
    assert not agent._has_pending_redirect() and not agent._interrupt_requested
    assert interrupt_mod.take_yield(1001) is YieldReason.OWNER_MESSAGE
    assert interrupt_mod.take_yield(1002) is YieldReason.OWNER_MESSAGE


@pytest.mark.parametrize("agent, restarts", [
    (Agent(model_active=True, streamed=[]), True),
    (Agent(model_active=True, streamed=["Here is the"]), False),
    (Agent(model_active=True, streamed=[], api_calls=1), False),
    (Agent(model_active=False), False),
], ids=["silent-request", "owner-is-reading-the-reply", "first-request-of-the-turn", "between-requests"])
def test_absorbing_during_a_model_request_restarts_it_only_while_nothing_visible_was_streamed(agent, restarts):
    assert agent.absorb("one more thing", ticket="adm_1") is True
    assert agent._pending_steer == "one more thing"
    assert agent._interrupt_requested is restarts
    assert agent._has_pending_redirect() is restarts
    assert agent._drain_pending_redirect() is None, "the restart carries no correction text: the steer row does"
    assert interrupt_mod.take_yield(1001) is None


def test_two_absorbs_before_a_drain_become_one_user_row_that_names_both_admissions():
    agent = Agent(executing_tools=True)
    messages = [
        {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function",
                                                              "function": {"name": "terminal", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "c1", "content": "partial output"},
    ]
    prefix = json.dumps(messages, sort_keys=True)
    agent.absorb("first", ticket="adm_1")
    agent.absorb("second", ticket="adm_2")
    deliver_steer_row(agent, messages, agent._drain_pending_steer(), index=len(messages))

    assert [m["role"] for m in messages] == ["assistant", "tool", "user"]
    assert json.dumps(messages[:2], sort_keys=True) == prefix, "the cached prefix must not change"
    row = messages[2]
    assert row["display_kind"] == "steer" and row["display_metadata"] == {"admission_ids": ["adm_1", "adm_2"]}
    assert "first\nsecond" in row["content"] and row["message_uid"]
    assert agent.absorbed == [{"admission_ids": ["adm_1", "adm_2"], "message_uid": row["message_uid"],
                               "text": "first\nsecond"}]


def test_a_plain_steer_without_an_admission_writes_a_row_and_announces_nothing():
    agent = Agent(executing_tools=True)
    messages = [{"role": "tool", "tool_call_id": "c1", "content": "x"}]
    agent.steer("desktop steer")
    deliver_steer_row(agent, messages, agent._drain_pending_steer())
    assert messages[1]["display_kind"] == "steer" and "display_metadata" not in messages[1]
    assert agent.absorbed == []


def test_an_owner_stop_after_absorbing_leaves_the_admission_unread_so_it_goes_back_to_its_queue():
    agent = Agent(executing_tools=True)
    agent.absorb("never mind, new plan", ticket="adm_1")
    agent.clear_interrupt(hard_cancel=True)
    assert agent.withdraw_steer("adm_1") is True
    assert agent._pending_steer is None
