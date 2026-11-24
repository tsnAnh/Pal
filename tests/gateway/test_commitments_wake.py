"""The commitment wake job against a real per-profile state.db, cron store and reach log: the script gate that
keeps an idle tick free of a model turn, the per-commitment escalation to stuck, one reach offer per owner-facing
event in the chat the promise was made in, the reach policy for requested versus initiated promises, the wake job
created once on the first promise, and the read-only `/reach ledger` view."""

import asyncio
import json
import time

import pytest

from gateway import commitments as cm
from gateway import commitments_wake as wake
from gateway import reach, reach_log
from gateway.commitments import Actor, Details, Route, State
from gateway.session_context import clear_session_vars, set_session_vars
from hermes_cli import proactive_cmd
from tests.gateway.reach_harness import (
    PROACTIVE_ON, FakeAppTransport, attach, make_authority, make_home, rows, run_with_owner, telegram_runner,
)
from tests.waiting import async_wait_until
from tools import commitment_tool

NOW = time.time()
HOUR = 60 * 60
TELEGRAM = Route(platform="telegram", chat_id="42", chat_type="dm", session_id="s1")
COMPLETE = Details(next_step="send the draft", blocker_what="the API key", blocker_who="owner",
                   evidence="PR #12 merged", reason="plans changed")
ALL_DAY_QUIET = "proactive:\n  enabled: true\n  min_gap_minutes: 0\n  quiet_hours: {start: '00:00', end: '23:59'}\n"
_keys = iter(range(10_000))


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = make_home(tmp_path, "profile")
    monkeypatch.setenv("HERMES_HOME", str(path))
    import hermes_time
    hermes_time.reset_cache()
    reach_log._recovered.clear()
    return path


def promise(home, *, due_at=None, owner_requested=True, route=TELEGRAM, text="Ship the report", now=NOW):
    return cm.promise(home, event_key=f"k{next(_keys)}", profile="main", text=text, owner_requested=owner_requested,
                      due_at=due_at, route=route, now=now).commitment_id


def move(home, commitment_id, to, *, actor=Actor.BOT, now=NOW):
    current = cm.get(home, commitment_id)
    return cm.transition(home, commitment_id, event_key=f"k{next(_keys)}", expected_rev=current.rev, to=to,
                         details=COMPLETE, actor=actor, now=now)


def gate_lines(home, now=NOW):
    return wake.gate(home, now).splitlines()


def wakes(home, now=NOW) -> bool:
    return json.loads(gate_lines(home, now)[-1])["wakeAgent"] is not False


def deliver_all(home, authority, now=NOW):
    async def scenario():
        return [await reach.offer(home, item, ack_timeout=0.3) for item in wake.offers_due(home, now)]
    return run_with_owner(authority, scenario)


def by_kind(home) -> dict[str, dict]:
    return {row["producer_key"].split(":")[2]: row for row in rows(home)}


def test_an_empty_ledger_never_wakes_the_model(home):
    assert gate_lines(home) == ['{"wakeAgent": false}']


def test_a_ledger_of_healthy_and_reported_promises_never_wakes_the_model(home):
    promise(home)
    move(home, promise(home, due_at=NOW + HOUR), State.IN_PROGRESS)
    move(home, promise(home, due_at=NOW - HOUR), State.BLOCKED)
    move(home, promise(home, due_at=NOW - HOUR), State.DONE)
    move(home, promise(home, due_at=NOW - HOUR), State.ABANDONED)
    assert not wakes(home)
    assert all(c.checks_since_progress == 0 for c in cm.list_active(home))


def test_an_overdue_promise_wakes_the_model_with_its_id_and_counts_the_check(home):
    late = promise(home, due_at=NOW - HOUR)
    lines = gate_lines(home)
    assert json.loads(lines[-1]) == {"wakeAgent": True}
    assert any(late in line and "Ship the report" in line for line in lines[:-1])
    assert cm.get(home, late).checks_since_progress == 1


def test_wakes_without_progress_turn_the_promise_stuck_and_stop_waking_it(home):
    late = promise(home, due_at=NOW - HOUR)
    for _ in range(cm.STUCK_AFTER_CHECKS):
        assert wakes(home)
    assert cm.get(home, late).stuck(NOW)
    assert not wakes(home)
    assert "stuck" in {item.producer_key.split(":")[2] for item in wake.offers_due(home, NOW)}


def test_progress_resets_the_escalation(home):
    late = promise(home, due_at=NOW - HOUR)
    for _ in range(cm.STUCK_AFTER_CHECKS - 1):
        assert wakes(home)
    move(home, late, State.IN_PROGRESS)
    assert not cm.get(home, late).stuck(NOW)
    assert wakes(home)


def test_each_owner_facing_event_is_one_offer_and_a_repeat_offers_nothing(home):
    authority = make_authority(home, telegram_runner())
    move(home, promise(home, text="done one"), State.DONE)
    move(home, promise(home, text="blocked one"), State.BLOCKED)
    promise(home, text="late one", due_at=NOW - HOUR)
    move(home, promise(home, text="stale one"), State.IN_PROGRESS, now=NOW - cm.STUCK_AFTER_SECONDS - 1)
    move(home, promise(home, text="dropped one"), State.ABANDONED)
    first = deliver_all(home, authority)
    second = deliver_all(home, authority)
    kinds = sorted(row["producer_key"].split(":")[2] for row in rows(home))
    assert kinds == ["abandoned", "blocked", "done", "overdue", "stuck"]
    assert len(first) == 5 and second == []
    assert all(row["domain"] == "commitments" and row["kind"] == "notify" for row in rows(home))
    assert by_kind(home)["blocked"]["title"] == "Blocked: blocked one"


def test_the_producer_key_names_the_commitment_the_event_and_the_revision(home):
    blocked = promise(home)
    rev = move(home, blocked, State.BLOCKED).rev
    assert [item.producer_key for item in wake.offers_due(home, NOW)] == [f"commit:{blocked}:blocked:{rev}"]


def test_a_new_block_is_a_new_event_but_the_same_block_is_not(home):
    authority = make_authority(home, telegram_runner())
    blocked = promise(home)
    move(home, blocked, State.BLOCKED)
    deliver_all(home, authority)
    deliver_all(home, authority)
    move(home, blocked, State.BLOCKED)
    deliver_all(home, authority)
    assert len(rows(home)) == 2


def test_healthy_progress_and_an_owner_drop_are_silent(home):
    move(home, promise(home, due_at=NOW + HOUR), State.IN_PROGRESS)
    promise(home)
    move(home, promise(home), State.ABANDONED, actor=Actor.OWNER)
    assert wake.offers_due(home, NOW) == []


def test_the_blocked_alert_carries_the_blocker_and_the_prepared_next_step_to_the_promise_chat(home):
    runner = telegram_runner(chat_id="555")
    authority = make_authority(home, runner)
    move(home, promise(home), State.BLOCKED)
    deliver_all(home, authority)
    assert len(runner.sent) == 1
    platform, chat_id, text = runner.sent[0]
    assert (platform, chat_id) == ("telegram", "42")
    assert "the API key" in text and "owner" in text and "send the draft" in text


def test_owner_requested_and_bot_initiated_promises_both_defer_through_quiet_hours(home):
    (home / "config.yaml").write_text(ALL_DAY_QUIET, encoding="utf-8")
    authority = make_authority(home, telegram_runner())
    move(home, promise(home, text="asked", owner_requested=True), State.DONE)
    move(home, promise(home, text="offered", owner_requested=False), State.DONE)
    deliveries = deliver_all(home, authority)
    assert [d.disposition for d in deliveries] == [reach.Disposition.DEFERRED, reach.Disposition.DEFERRED]
    assert {row["consent"]: row["reason"] for row in rows(home)} == {"requested": "quiet_hours",
                                                                       "initiated": "quiet_hours"}
    assert authority.runner.sent == []


def test_the_quiet_hours_do_not_stop_a_wake(home):
    (home / "config.yaml").write_text(ALL_DAY_QUIET, encoding="utf-8")
    promise(home, due_at=NOW - HOUR)
    assert wakes(home)


def test_the_daily_alert_budget_holds_back_bot_initiated_promises_only(home):
    (home / "config.yaml").write_text("proactive:\n  enabled: true\n  quiet_hours: null\n  min_gap_minutes: 0\n"
                                      "  daily_budget: 0\n", encoding="utf-8")
    authority = make_authority(home, telegram_runner())
    move(home, promise(home, text="asked", owner_requested=True), State.DONE)
    move(home, promise(home, text="offered", owner_requested=False), State.DONE)
    deliver_all(home, authority)
    found = {row["consent"]: (row["status"], row["reason"]) for row in rows(home)}
    assert found == {"requested": ("alerted", ""), "initiated": ("landed_silent", "budget")}


def test_bot_initiated_promises_stay_silent_while_proactive_alerts_are_off(home):
    (home / "config.yaml").write_text("proactive:\n  enabled: false\n  quiet_hours: null\n", encoding="utf-8")
    authority = make_authority(home, telegram_runner())
    move(home, promise(home, owner_requested=False), State.DONE)
    deliver_all(home, authority)
    assert [(row["status"], row["reason"]) for row in rows(home)] == [("suppressed", "disabled")]
    assert authority.runner.sent == []


def test_the_commitments_domain_is_a_notify_tier_by_default():
    from gateway.reach_policy import Tier, load_policy
    assert load_policy({}).domain_tiers["commitments"] is Tier.NOTIFY


SCORECARD_OFF = PROACTIVE_ON + "  domain_tiers: {scorecard: 'off'}\n"


def test_the_tick_reporter_offers_through_the_owning_gateway(home):
    (home / "config.yaml").write_text(SCORECARD_OFF, encoding="utf-8")
    wake.write_gate_script(home)
    authority = make_authority(home, telegram_runner())
    move(home, promise(home), State.DONE)

    async def scenario():
        await asyncio.to_thread(wake.report_due, home)
        await async_wait_until(lambda: authority.runner.sent, what="done alert sent")
        return authority.runner.sent

    assert len(run_with_owner(authority, scenario)) == 1


def test_the_tick_reporter_does_nothing_for_a_bot_that_never_promised_without_a_scorecard(home):
    (home / "config.yaml").write_text(SCORECARD_OFF, encoding="utf-8")
    assert wake.report_due(home) == 0
    assert rows(home) == []


@pytest.fixture
def bound(home):
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", session_id="s1", profile="main")
    yield home
    clear_session_vars(tokens)


def wake_jobs():
    from cron.jobs import load_jobs
    return [job for job in load_jobs() if job.get("script") == wake.SCRIPT_NAME]


def test_the_first_promise_creates_one_wake_job_and_later_promises_reuse_it(bound):
    assert wake_jobs() == []
    for text in ("first", "second"):
        made = json.loads(commitment_tool.commitment_tool({"action": "promise", "text": text, "owner_requested": True}))
        assert "id" in made and "follow_up_error" not in made
    jobs = wake_jobs()
    assert len(jobs) == 1
    assert jobs[0]["schedule"]["kind"] == "interval" and jobs[0]["schedule"]["minutes"] == 15
    assert jobs[0]["deliver"] == "local" and jobs[0]["no_agent"] is False
    assert (bound / "scripts" / wake.SCRIPT_NAME).is_file()


def test_a_paused_wake_job_is_left_paused(bound):
    from cron.jobs import pause_job
    wake.ensure_job()
    pause_job(wake_jobs()[0]["id"])
    wake.ensure_job()
    assert [job["state"] for job in wake_jobs()] == ["paused"]


def test_the_cron_runner_executes_the_gate_file_and_reads_its_verdict(bound):
    from cron.scheduler_prompt import _parse_wake_gate
    from cron.scheduler_script import _run_job_script
    wake.ensure_job()
    ok, output = _run_job_script(wake.SCRIPT_NAME)
    assert ok, output
    assert _parse_wake_gate(output) is False
    promise(bound, due_at=time.time() - HOUR)
    ok, output = _run_job_script(wake.SCRIPT_NAME)
    assert ok and _parse_wake_gate(output) is True and "Ship the report" in output


def test_reach_ledger_lists_open_promises_with_their_computed_facts(home):
    late = promise(home, text="Send the invoice", due_at=time.time() - HOUR)
    blocked = promise(home, text="Book the venue")
    move(home, blocked, State.BLOCKED, now=time.time())
    move(home, promise(home, text="Already shipped"), State.DONE)
    text = proactive_cmd.handle_proactive_command("ledger")
    assert "Send the invoice" in text and "Book the venue" in text and "Already shipped" not in text
    late_line = next(line for line in text.splitlines() if late in line)
    assert "open" in late_line and "overdue" in late_line
    assert "the API key" in text and "send the draft" in text
    assert cm.get(home, late).checks_since_progress == 0


def test_reach_ledger_on_a_bot_without_promises_says_so(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    assert proactive_cmd.handle_proactive_command("ledger") == "No open promises."
    assert not (tmp_path / "state.db").exists()
