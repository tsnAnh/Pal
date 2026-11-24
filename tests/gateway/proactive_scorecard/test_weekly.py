"""The weekly scorecard offer through the real reach pipeline: one suggest offer per ISO week, built in code from
the numbers, judged by the reach policy (mute, quiet hours, proactive off), riding the per-bot wake job whose gate
stays silent, and ensured for a bot that never promised anything."""

import asyncio
import json
from datetime import datetime, timedelta

import pytest

from gateway import commitments_wake as wake
from gateway import reach, reach_log
from gateway.commitments import State
from gateway.proactive_scorecard import weekly
from gateway.reach_policy import Consent, OfferKind, Tier, load_policy
from gateway.session_context import clear_session_vars, set_session_vars
from tests.gateway.proactive_scorecard.card_fixture import DAY, NOW, SENTINEL, conversation, move, promise
from tests.gateway.reach_harness import make_authority, make_home, rows, run_with_owner, telegram_runner
from tests.waiting import async_wait_until

ON = "proactive:\n  enabled: true\n  quiet_hours: null\n  min_gap_minutes: 0\n"


def local_now():
    import hermes_time
    return hermes_time.now()


def last_week(now_local: datetime) -> str:
    year, week, _ = (now_local - timedelta(days=7)).isocalendar()
    return f"{year}-W{week:02d}"


@pytest.fixture
def make(tmp_path, monkeypatch):
    def build(config: str = ON, name: str = "bot"):
        home = make_home(tmp_path, name, config)
        monkeypatch.setenv("HERMES_HOME", str(home))
        import hermes_time
        hermes_time.reset_cache()
        reach_log._recovered.clear()
        weekly._attempted.clear()
        return home
    return build


def deliver(home, item, runner=None):
    authority = make_authority(home, runner or telegram_runner())

    async def scenario():
        return await reach.offer(home, item, ack_timeout=0.3)
    return run_with_owner(authority, scenario), authority


def test_the_scorecard_domain_is_a_suggest_tier_by_default():
    assert load_policy({}).domain_tiers[weekly.DOMAIN] is Tier.SUGGEST


def test_the_weekly_offer_scores_last_iso_week_as_a_bot_initiated_suggestion(make):
    home = make()
    item = weekly.offer_due(home, local_now())
    assert item.producer_key == f"scorecard:{last_week(local_now())}"
    assert (item.domain, item.kind, item.consent) == ("scorecard", OfferKind.SUGGEST, Consent.INITIATED)
    assert last_week(local_now()) in item.title and item.lane is None and item.chat is None


def test_the_headline_names_what_moved_most_and_holds_no_text(make):
    home = make()
    now_local = local_now()
    start = weekly.week_window(now_local)[1].since
    done = promise(home, at=start + DAY, due_at=start + 2 * DAY)
    move(home, done, State.DONE, at=start + DAY + 60)
    old = promise(home, at=start - 6 * DAY, due_at=start - 5 * DAY)
    move(home, old, State.ABANDONED, at=start - 5 * DAY + 60)
    conversation(home)
    item = weekly.offer_due(home, now_local)
    assert "kept rate 0.00 → 1.00" in item.body
    assert SENTINEL not in item.title and SENTINEL not in item.body
    assert "HARD FAIL" not in item.body


def test_one_offer_per_iso_week(make):
    home = make()
    item = weekly.offer_due(home, local_now())
    first, authority = deliver(home, item)
    assert first.disposition is reach.Disposition.ALERTED and len(authority.runner.sent) == 1
    weekly._attempted.clear()
    assert weekly.offer_due(home, local_now()) is None
    deliver(home, item)
    assert [row["producer_key"] for row in rows(home)] == [f"scorecard:{last_week(local_now())}"]


def test_a_muted_scorecard_lands_silently(make):
    home = make(ON + "  muted_domains: [scorecard]\n")
    _, authority = deliver(home, weekly.offer_due(home, local_now()))
    assert [(row["status"], row["reason"]) for row in rows(home)] == [("landed_silent", "muted")]
    assert authority.runner.sent == []


def test_quiet_hours_defer_the_scorecard(make):
    home = make("proactive:\n  enabled: true\n  min_gap_minutes: 0\n  quiet_hours: {start: '00:00', end: '23:59'}\n")
    _, authority = deliver(home, weekly.offer_due(home, local_now()))
    assert [(row["status"], row["reason"]) for row in rows(home)] == [("deferred", "quiet_hours")]
    assert authority.runner.sent == []


def test_the_scorecard_is_off_while_proactive_alerts_are_off(make):
    home = make("proactive:\n  enabled: false\n")
    assert not weekly.enabled(home)
    assert wake.report_due(home) == 0
    assert rows(home) == [] and not (home / "scripts" / wake.SCRIPT_NAME).exists()


def test_a_tier_of_off_turns_the_scorecard_off(make):
    home = make(ON + "  domain_tiers: {scorecard: 'off'}\n")
    assert not weekly.enabled(home)


def test_a_due_scorecard_never_wakes_the_model(make):
    home = make()
    assert weekly.offer_due(home, local_now()) is not None
    assert wake.gate(home, NOW) == json.dumps({"wakeAgent": False})


@pytest.fixture
def bound(make):
    home = make()
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", session_id="s1", profile="main")
    yield home
    clear_session_vars(tokens)


def test_a_bot_that_never_promised_gets_the_wake_job_and_its_weekly_offer(bound):
    from cron.jobs import load_jobs
    authority = make_authority(bound, telegram_runner())

    async def scenario():
        await asyncio.to_thread(wake.report_due, bound)
        await async_wait_until(lambda: authority.runner.sent, what="scorecard alert sent")
        return authority.runner.sent

    assert len(run_with_owner(authority, scenario)) == 1
    assert [job["script"] for job in load_jobs()] == [wake.SCRIPT_NAME]
    assert [row["domain"] for row in rows(bound)] == ["scorecard"]
    assert wake.report_due(bound) == 0
