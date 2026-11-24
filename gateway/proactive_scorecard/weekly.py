from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from gateway import reach, reach_log
from gateway.proactive_scorecard import card
from gateway.proactive_scorecard.card import Scorecard, Window
from gateway.reach_policy import Tier, load_policy

DOMAIN = "scorecard"
_attempted: set[tuple[str, str]] = set()


def iso_week(moment: datetime) -> str:
    year, week, _ = moment.isocalendar()
    return f"{year}-W{week:02d}"


def week_window(now_local: datetime) -> tuple[Window, Window]:
    monday = (now_local - timedelta(days=now_local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    last = monday - timedelta(days=7)
    before = last - timedelta(days=7)
    return Window(before.timestamp(), last.timestamp()), Window(last.timestamp(), monday.timestamp())


def enabled(home) -> bool:
    from hermes_cli.config_effective import load_user_config_effective
    policy = load_policy(load_user_config_effective(Path(home) / "config.yaml"))
    return policy.enabled and policy.domain_tiers.get(DOMAIN, Tier.OFF) is not Tier.OFF


def headline(before: Scorecard, after: Scorecard) -> str:
    moved = [f"{move.label} {card.format_value(move.before)} → {card.format_value(move.after)}"
             for move in card.moved_most(card.compare(before, after))]
    text = f"Moved most: {'; '.join(moved)}." if moved else "Nothing moved since the week before."
    violations = after.metrics["gate_violations"]
    if violations.hard_fail:
        text = f"HARD FAIL: {violations.numerator} gate violation(s), must be 0. {text}"
    return f"{text} Full card: /reach score 14d."


def offer_due(home, now_local: datetime) -> reach.Offer | None:
    before_window, last_window = week_window(now_local)
    week = iso_week(datetime.fromtimestamp(last_window.since, now_local.tzinfo))
    producer_key = f"{DOMAIN}:{week}"
    marker = (str(Path(home).resolve()), producer_key)
    if marker in _attempted or reach_log.known_producer_keys(home, [producer_key]):
        return None
    _attempted.add(marker)
    now = now_local.timestamp()
    before = card.compute(before_window, home, now=now)
    after = card.compute(last_window, home, now=now)
    return reach.Offer(producer_key=producer_key, domain=DOMAIN, kind=reach.OfferKind.SUGGEST,
                       consent=reach.Consent.INITIATED, title=f"Scorecard {week}", body=headline(before, after))
