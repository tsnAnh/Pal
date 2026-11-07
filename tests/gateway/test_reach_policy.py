"""Proactive-offer policy: judge as a data table, rank order, and the config keys through their loader."""

from datetime import datetime, time, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

from gateway.reach_policy import (
    AppSocket, Consent, LogView, Messaging, OfferKind, Policy, QuietHours, Route, Tier, judge, load_policy, rank,
)
from gateway.reach_presence import Attention

NY = ZoneInfo("America/New_York")
TOKYO = ZoneInfo("Asia/Tokyo")
EMPTY = LogView(0, None)


def policy(**changes) -> Policy:
    base = dict(enabled=True, domain_tiers={"cron": Tier.NOTIFY, "suggestions": Tier.SUGGEST}, daily_budget=3,
                min_gap=timedelta(minutes=60), quiet=None, muted=frozenset())
    return Policy(**{**base, **changes})


def offer(consent=Consent.INITIATED, domain="cron", kind=OfferKind.NOTIFY):
    return SimpleNamespace(consent=consent, domain=domain, kind=kind)


def at(hour, minute=0, tz=NY, day=(2026, 6, 10)):
    return datetime(*day, hour, minute, tzinfo=tz)


QUIET = QuietHours(time(22, 0), time(8, 0))
NOON = at(12)

VERDICT_TABLE = [
    ("initiated alert allowed", offer(), policy(), EMPTY, NOON, (True, True, None, "")),
    ("disabled drops an initiated offer", offer(), policy(enabled=False), EMPTY, NOON, (False, False, None, "disabled")),
    ("domain tier off drops it", offer(domain="cron"), policy(domain_tiers={"cron": Tier.OFF}), EMPTY, NOON,
     (False, False, None, "tier_off")),
    ("unlisted domain is off", offer(domain="other"), policy(), EMPTY, NOON, (False, False, None, "tier_off")),
    ("notify needs tier notify", offer(domain="suggestions", kind=OfferKind.NOTIFY), policy(), EMPTY, NOON,
     (False, False, None, "tier_off")),
    ("suggest is allowed by tier suggest", offer(domain="suggestions", kind=OfferKind.SUGGEST), policy(), EMPTY, NOON,
     (True, True, None, "")),
    ("suggest is allowed by tier notify", offer(domain="cron", kind=OfferKind.SUGGEST), policy(), EMPTY, NOON,
     (True, True, None, "")),
    ("daily budget exhausted lands silently", offer(), policy(daily_budget=2), LogView(2, NOON.timestamp() - 7200), NOON,
     (True, False, None, "budget")),
    ("zero budget never alerts", offer(), policy(daily_budget=0), EMPTY, NOON, (True, False, None, "budget")),
    ("min gap not elapsed", offer(), policy(), LogView(1, NOON.timestamp() - 600), NOON, (True, False, None, "min_gap")),
    ("min gap elapsed", offer(), policy(), LogView(1, NOON.timestamp() - 3700), NOON, (True, True, None, "")),
    ("muted domain lands silently", offer(), policy(muted=frozenset({"cron"})), EMPTY, NOON, (True, False, None, "muted")),
    ("requested bypasses disabled", offer(Consent.REQUESTED), policy(enabled=False), EMPTY, NOON, (True, True, None, "")),
    ("requested bypasses tier off", offer(Consent.REQUESTED), policy(domain_tiers={}), EMPTY, NOON, (True, True, None, "")),
    ("requested bypasses budget and gap", offer(Consent.REQUESTED), policy(daily_budget=1),
     LogView(5, NOON.timestamp() - 5), NOON, (True, True, None, "")),
    ("requested still honours mute", offer(Consent.REQUESTED), policy(muted=frozenset({"cron"})), EMPTY, NOON,
     (True, False, None, "muted")),
]


@pytest.mark.parametrize("name,item,pol,view,now,expected", VERDICT_TABLE, ids=[row[0] for row in VERDICT_TABLE])
def test_judge_table(name, item, pol, view, now, expected):
    verdict = judge(item, pol, view, now)
    assert (verdict.land, verdict.alert, verdict.defer_until, verdict.reason) == expected


QUIET_TABLE = [
    ("before midnight defers to next morning", NY, (2026, 6, 10), (23, 0), (2026, 6, 11, 8, 0)),
    ("after midnight defers to same morning", NY, (2026, 6, 11), (3, 30), (2026, 6, 11, 8, 0)),
    ("exactly at start is quiet", NY, (2026, 6, 10), (22, 0), (2026, 6, 11, 8, 0)),
    ("exactly at end is awake", NY, (2026, 6, 10), (8, 0), None),
    ("midday is awake", NY, (2026, 6, 10), (13, 0), None),
    ("non-UTC zone judged by its own wall clock", TOKYO, (2026, 6, 10), (23, 30), (2026, 6, 11, 8, 0)),
    ("spring forward night: the window ends at 08:00 EDT", NY, (2026, 3, 7), (23, 30), (2026, 3, 8, 8, 0)),
    ("spring forward after the jump", NY, (2026, 3, 8), (3, 30), (2026, 3, 8, 8, 0)),
    ("fall back night: the window ends at 08:00 EST", NY, (2026, 10, 31), (23, 30), (2026, 11, 1, 8, 0)),
    ("fall back second 01:30 is still quiet", NY, (2026, 11, 1), (1, 30), (2026, 11, 1, 8, 0)),
]


@pytest.mark.parametrize("name,tz,day,clock,deferred_to", QUIET_TABLE, ids=[row[0] for row in QUIET_TABLE])
def test_quiet_hours_across_midnight_and_dst(name, tz, day, clock, deferred_to):
    now = datetime(*day, *clock, tzinfo=tz)
    verdict = judge(offer(Consent.REQUESTED), policy(quiet=QUIET), EMPTY, now)
    assert verdict.land is True
    if deferred_to is None:
        assert verdict.alert is True and verdict.defer_until is None
    else:
        assert verdict.alert is False and verdict.reason == "quiet_hours"
        assert verdict.defer_until == datetime(*deferred_to, tzinfo=tz).timestamp()


def test_quiet_hours_apply_to_requested_and_initiated_alike():
    for consent in (Consent.REQUESTED, Consent.INITIATED):
        verdict = judge(offer(consent), policy(quiet=QUIET), EMPTY, at(23))
        assert (verdict.land, verdict.alert, verdict.reason) == (True, False, "quiet_hours")


def test_refusals_outrank_quiet_hours_deferral():
    verdict = judge(offer(), policy(quiet=QUIET, enabled=False), EMPTY, at(23))
    assert verdict.defer_until is None and verdict.reason == "disabled"


def route(attention, last_input=None, attention_at=None, tid="t"):
    return Route(channel=AppSocket(tid), attention=attention, last_input_at=last_input, attention_at=attention_at)


def test_rank_orders_attention_then_input_then_attention_time_and_drops_parked():
    engaged_old = route(Attention.ENGAGED, 10.0, 5.0, "engaged-old")
    engaged_new = route(Attention.ENGAGED, 20.0, 1.0, "engaged-new")
    engaged_tie_late = route(Attention.ENGAGED, 20.0, 9.0, "engaged-tie-late")
    attached = route(Attention.ATTACHED, 99.0, 99.0, "attached")
    reachable = Route(channel=Messaging("telegram", "1"), attention=Attention.REACHABLE, last_input_at=None, attention_at=None)
    parked = route(Attention.PARKED, 100.0, 100.0, "parked")
    ranked = rank([parked, reachable, attached, engaged_old, engaged_tie_late, engaged_new])
    assert [r.channel for r in ranked] == [
        engaged_tie_late.channel, engaged_new.channel, engaged_old.channel, attached.channel, reachable.channel]


def test_config_keys_reach_policy_through_the_effective_loader(tmp_path):
    from hermes_cli.config_effective import load_user_config_effective
    config = tmp_path / "config.yaml"
    config.write_text(
        "proactive:\n"
        "  enabled: true\n"
        "  daily_budget: 7\n"
        "  min_gap_minutes: 15\n"
        "  quiet_hours: {start: '23:30', end: '06:45'}\n"
        "  domain_tiers: {cron: suggest, suggestions: off, watch: notify}\n"
        "  muted_domains: [suggestions]\n"
        "  messaging_window_minutes: 5\n", encoding="utf-8")
    loaded = load_policy(load_user_config_effective(config))
    assert loaded.enabled is True and loaded.daily_budget == 7
    assert loaded.min_gap == timedelta(minutes=15)
    assert loaded.quiet == QuietHours(time(23, 30), time(6, 45))
    assert dict(loaded.domain_tiers) == {"cron": Tier.SUGGEST, "suggestions": Tier.OFF, "watch": Tier.NOTIFY}
    assert loaded.muted == frozenset({"suggestions"})
    assert loaded.messaging_window == timedelta(minutes=5)


def test_absent_or_invalid_config_falls_back_to_the_safe_defaults(tmp_path):
    from hermes_cli.config_effective import load_user_config_effective
    defaults = load_policy(load_user_config_effective(tmp_path / "missing.yaml"))
    assert defaults.enabled is False and defaults.daily_budget == 3
    assert defaults.min_gap == timedelta(minutes=60) and defaults.messaging_window == timedelta(minutes=30)
    assert defaults.quiet == QuietHours(time(22, 0), time(8, 0))
    assert defaults.domain_tiers["cron"] is Tier.NOTIFY and defaults.domain_tiers["suggestions"] is Tier.SUGGEST
    broken = load_policy({"proactive": {
        "enabled": "yes", "daily_budget": "lots", "quiet_hours": {"start": "late", "end": "08:00"},
        "domain_tiers": {"cron": "loud"}, "muted_domains": "cron"}})
    assert broken.enabled is False and broken.daily_budget == 3
    assert broken.quiet == QuietHours(time(22, 0), time(8, 0))
    assert broken.domain_tiers["cron"] is Tier.NOTIFY and broken.muted == frozenset()


def test_quiet_hours_can_be_switched_off():
    assert load_policy({"proactive": {"quiet_hours": None}}).quiet is None
    assert load_policy({"proactive": {"quiet_hours": {"start": "09:00", "end": "09:00"}}}).quiet is None
