"""The reach offer log in a real per-profile state.db: idempotent claims, budget derived in the claiming
transaction, restart fencing, and monotonic outcomes."""

import json
import threading
import time
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest

from gateway import reach_log
from gateway.reach_policy import Consent, OfferKind, Policy, Tier, Verdict, judge
from hermes_state import SessionDB
from tests.waiting import wait_until


@pytest.fixture
def home(tmp_path):
    SessionDB(db_path=tmp_path / "state.db").close()
    reach_log._recovered.clear()
    return tmp_path


def policy(**changes):
    base = dict(enabled=True, domain_tiers={"cron": Tier.NOTIFY}, daily_budget=3, min_gap=timedelta(0),
                quiet=None, muted=frozenset())
    return Policy(**{**base, **changes})


def claim(home, key, *, consent=Consent.INITIATED, pol=None, now=None, domain="cron"):
    pol = pol or policy()
    stamp = time.time() if now is None else now
    item = SimpleNamespace(consent=consent, domain=domain, kind=OfferKind.NOTIFY)
    local = datetime.fromtimestamp(stamp, tz=UTC)
    return reach_log.claim(
        home, producer_key=key, domain=domain, kind="notify", consent=consent.value, title="Title",
        judge=lambda view: judge(item, pol, view, local), now=stamp)


def test_same_producer_key_claims_once_and_never_alerts_twice(home):
    first = claim(home, "cron:job:run1")
    second = claim(home, "cron:job:run1")
    assert first.created and first.verdict.alert and first.row["status"] == "routing"
    assert not second.created and second.verdict is None
    assert second.row["offer_id"] == first.row["offer_id"]
    reach_log.finalize(home, first.row["offer_id"], status="alerted", reason="", route={"kind": "app"}, alerted_at=time.time())
    third = claim(home, "cron:job:run1")
    assert not third.created and third.row["status"] == "alerted"
    assert len(reach_log.list_offers(home)) == 1


def test_log_stores_title_but_never_a_body(home):
    reach_log.maintain(home, time.time())
    columns = {row[1] for row in reach_log._connect(home).execute("PRAGMA table_info(reach_offers)")}
    assert "title" in columns and not {"body", "content", "text"} & columns


def test_two_threads_against_a_budget_of_one_produce_exactly_one_alert(home):
    pol = policy(daily_budget=1)
    results = []
    barrier = threading.Barrier(2)

    def attempt(key):
        barrier.wait()
        results.append(claim(home, key, pol=pol))

    threads = [threading.Thread(target=attempt, args=(f"cron:job:{n}",)) for n in range(2)]
    for thread in threads:
        thread.start()
    wait_until(lambda: len(results) == 2, what="both claims settled")
    for thread in threads:
        thread.join()
    assert sorted(r.verdict.alert for r in results) == [False, True]
    assert sorted(r.row["status"] for r in results) == ["landed_silent", "routing"]
    assert [r.verdict.reason for r in results if not r.verdict.alert] == ["budget"]


def test_a_pending_alert_counts_against_the_budget_but_an_unreachable_one_releases_it(home):
    pol = policy(daily_budget=1)
    held = claim(home, "a", pol=pol)
    assert held.verdict.alert
    assert not claim(home, "b", pol=pol).verdict.alert
    reach_log.finalize(home, held.row["offer_id"], status="landed_silent", reason="no_route")
    assert claim(home, "c", pol=pol).verdict.alert


def test_requested_alerts_do_not_spend_the_initiated_budget(home):
    pol = policy(daily_budget=1)
    requested = claim(home, "user-job", consent=Consent.REQUESTED, pol=pol)
    reach_log.finalize(home, requested.row["offer_id"], status="alerted", reason="", alerted_at=time.time())
    assert claim(home, "hermes-job", pol=pol).verdict.alert


def test_min_gap_is_measured_from_the_last_initiated_alert(home):
    pol = policy(min_gap=timedelta(hours=1))
    start = time.time()
    first = claim(home, "a", pol=pol, now=start)
    reach_log.finalize(home, first.row["offer_id"], status="alerted", reason="", alerted_at=start)
    assert claim(home, "b", pol=pol, now=start + 600).verdict.reason == "min_gap"
    assert claim(home, "c", pol=pol, now=start + 3700).verdict.alert


def test_boot_recovery_fences_routing_rows_as_unknown_and_never_realerts(home):
    stranded = claim(home, "cron:job:run9")
    reach_log._recovered.clear()
    again = claim(home, "cron:job:run9")
    row = reach_log.get(home, stranded.row["offer_id"])
    assert row["status"] == "unknown" and row["reason"] == "interrupted"
    assert not again.created and again.verdict is None and again.row["status"] == "unknown"


def test_recovery_runs_once_per_process_so_a_live_claim_is_never_fenced(home):
    first = claim(home, "a")
    second = claim(home, "b")
    assert reach_log.get(home, first.row["offer_id"])["status"] == "routing"
    assert second.row["status"] == "routing"


def test_outcomes_only_move_forward_and_the_first_terminal_wins(home):
    offer_id = claim(home, "a").row["offer_id"]
    now = time.time()
    assert reach_log.record_outcome(home, offer_id, "shown", "device-1", now)[1] is True
    assert reach_log.record_outcome(home, offer_id, "shown", "device-2", now + 1)[1] is False
    row, applied = reach_log.record_outcome(home, offer_id, "acted", "device-1", now + 2)
    assert applied and row["outcome"] == "acted" and row["outcome_device"] == "device-1"
    assert reach_log.record_outcome(home, offer_id, "dismissed", "device-2", now + 3)[1] is False
    assert reach_log.record_outcome(home, offer_id, "shown", "device-2", now + 4)[1] is False
    final = reach_log.get(home, offer_id)
    assert final["outcome"] == "acted" and final["outcome_device"] == "device-1" and final["outcome_at"] == now + 2


def test_a_terminal_outcome_may_arrive_without_a_shown_and_unknown_offers_are_not_recorded(home):
    offer_id = claim(home, "a").row["offer_id"]
    assert reach_log.record_outcome(home, offer_id, "dismissed", None, time.time())[1] is True
    assert reach_log.record_outcome(home, "does-not-exist", "shown", None, time.time()) == (None, False)


def test_maintenance_expires_unseen_alerts_after_a_day_and_prunes_after_ninety(home):
    now = time.time()
    old_alert = claim(home, "old-alert", now=now - 2 * 86400)
    reach_log.finalize(home, old_alert.row["offer_id"], status="alerted", reason="", alerted_at=now - 2 * 86400)
    fresh = claim(home, "fresh", now=now - 3600)
    reach_log.finalize(home, fresh.row["offer_id"], status="alerted", reason="", alerted_at=now - 3600)
    seen = claim(home, "seen", now=now - 2 * 86400)
    reach_log.finalize(home, seen.row["offer_id"], status="alerted", reason="", alerted_at=now - 2 * 86400)
    reach_log.record_outcome(home, seen.row["offer_id"], "shown", None, now - 2 * 86400 + 5)
    ancient = claim(home, "ancient", now=now - 91 * 86400)
    reach_log.maintain(home, now)
    assert reach_log.get(home, old_alert.row["offer_id"])["outcome"] == "expired"
    assert reach_log.get(home, fresh.row["offer_id"])["outcome"] is None
    assert reach_log.get(home, seen.row["offer_id"])["outcome"] == "shown"
    assert reach_log.get(home, ancient.row["offer_id"]) is None


def test_deferred_rows_are_due_only_after_not_before_and_while_unshown(home):
    now = time.time()
    deferred = reach_log.claim(
        home, producer_key="q", domain="cron", kind="notify", consent="requested", title="t",
        judge=lambda view: Verdict(True, False, now + 100, "quiet_hours"), now=now)
    assert deferred.row["status"] == "deferred" and deferred.row["not_before"] == now + 100
    assert reach_log.due_deferred(home, now + 50) == []
    assert [r["offer_id"] for r in reach_log.due_deferred(home, now + 101)] == [deferred.row["offer_id"]]
    reach_log.record_outcome(home, deferred.row["offer_id"], "shown", None, now + 102)
    assert reach_log.due_deferred(home, now + 200) == []


def test_attempts_are_append_only_and_a_deferred_row_claims_once(home):
    now = time.time()
    deferred = reach_log.claim(
        home, producer_key="q", domain="cron", kind="notify", consent="requested", title="t",
        judge=lambda view: Verdict(True, False, now - 1, "quiet_hours"), now=now - 5)
    offer_id = deferred.row["offer_id"]
    awake = lambda view: Verdict(True, True, None, "")
    first = reach_log.claim_deferred(home, offer_id, judge=awake, now=now)
    second = reach_log.claim_deferred(home, offer_id, judge=awake, now=now)
    assert first.verdict.alert and first.row["status"] == "routing" and second is None
    reach_log.append_attempt(home, offer_id, {"result": "no_ack"})
    reach_log.append_attempt(home, offer_id, {"result": "ack"})
    assert [a["result"] for a in json.loads(reach_log.get(home, offer_id)["attempts_json"])] == ["no_ack", "ack"]
