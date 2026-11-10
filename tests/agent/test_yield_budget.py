"""``bot_mode.background_after_seconds``: a Bot Chat turn bounds every blocking tool batch by asking its
workers to yield with the BUDGET reason, resolved per owning profile and never for other sessions."""
import threading
from types import SimpleNamespace

import pytest

from agent.tool_yield_budget import YieldPolicy, batch_yield_budget, resolve_yield_policy
from tools import interrupt as interrupt_mod
from tools.interrupt import YieldReason
from tests.waiting import wait_until


def _agent(policy, *, turn_author=None):
    return SimpleNamespace(yield_policy=policy, _turn_author=turn_author,
                           _tool_worker_threads=set(), _tool_worker_threads_lock=threading.Lock())


def _worker(agent):
    registered, release = threading.Event(), threading.Event()
    tids = []

    def run():
        tids.append(threading.current_thread().ident)
        with agent._tool_worker_threads_lock:
            agent._tool_worker_threads.add(tids[0])
        registered.set()
        release.wait(30)
        with agent._tool_worker_threads_lock:
            agent._tool_worker_threads.discard(tids[0])
        interrupt_mod.set_interrupt(False, tids[0])

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    assert registered.wait(15)
    return tids[0], release, thread


def test_a_batch_still_running_past_the_budget_asks_every_worker_to_yield_with_the_budget_reason():
    agent = _agent(YieldPolicy(0.2))
    first, release_first, thread_first = _worker(agent)
    second, release_second, thread_second = _worker(agent)
    try:
        with batch_yield_budget(agent, lambda: 0.0):
            wait_until(lambda: interrupt_mod.is_thread_yield_requested(second), timeout=15, what="the budget to fire")
        assert interrupt_mod.take_yield(first) is YieldReason.BUDGET
        assert interrupt_mod.take_yield(second) is YieldReason.BUDGET
    finally:
        release_first.set()
        release_second.set()
        thread_first.join(5)
        thread_second.join(5)


def test_a_batch_that_returns_inside_the_budget_leaves_no_timer_and_no_pending_yield():
    agent = _agent(YieldPolicy(0.2))
    tid, release, thread = _worker(agent)
    try:
        with batch_yield_budget(agent, lambda: 0.0):
            pass
        wait_until(lambda: not any(t.name == "tool-yield-budget" for t in threading.enumerate()), timeout=15,
                   what="the budget timer to end")
        assert not interrupt_mod.is_thread_yield_requested(tid)
    finally:
        release.set()
        thread.join(5)


@pytest.mark.parametrize("agent", [
    _agent(None), _agent(YieldPolicy(0.2), turn_author={"id": "bot:peer", "name": "peer", "is_bot": True}),
], ids=["no-policy", "bot-authored-turn"])
def test_sessions_without_a_policy_and_bot_authored_turns_are_never_yielded(agent):
    tid, release, thread = _worker(agent)
    try:
        with batch_yield_budget(agent, lambda: 0.0):
            assert threading.Event().wait(0.5) is False  # health: allow HX013 -- the absence of a yield across the policy window is the behaviour
        assert not interrupt_mod.is_thread_yield_requested(tid)
    finally:
        release.set()
        thread.join(5)


@pytest.fixture
def bot_chat(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / "profiles" / "chief").mkdir(parents=True)
    (home / "profiles" / "chief" / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    title: Chief\n")
    monkeypatch.setenv("HERMES_HOME", str(home))
    db_path = home / "state.db"
    return SimpleNamespace(_bot_mode_protocol=True, _session_title_hint="Bot Chat", session_id="s",
                           _session_db=SimpleNamespace(db_path=db_path))


@pytest.mark.parametrize("config, expected", [
    ({}, 20.0),
    ({"bot_mode": {"background_after_seconds": 7}}, 7.0),
    ({"bot_mode": {"background_after_seconds": 0}}, None),
    ({"bot_mode": {"background_after_seconds": "soon"}}, 20.0),
    ({"bot_mode": {"background_after_seconds": -5}}, 20.0),
    ({"bot_mode": None}, 20.0),
])
def test_the_budget_comes_from_the_profile_config_for_a_bot_chat(bot_chat, config, expected):
    policy = resolve_yield_policy(bot_chat, config)
    assert (policy.background_after_s if policy else None) == expected


def test_a_session_that_is_not_the_bot_chat_gets_no_policy(bot_chat):
    bot_chat._session_title_hint = "Weekend plans"
    assert resolve_yield_policy(bot_chat, {"bot_mode": {"background_after_seconds": 5}}) is None
