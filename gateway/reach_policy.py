from __future__ import annotations

import logging
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, time, timedelta
from enum import StrEnum

from gateway.reach_presence import Attention

logger = logging.getLogger(__name__)

DEFAULT_DAILY_BUDGET = 3
DEFAULT_MIN_GAP_MINUTES = 60
DEFAULT_MESSAGING_WINDOW_MINUTES = 30
DEFAULT_QUIET_START = "22:00"
DEFAULT_QUIET_END = "08:00"
DEFAULT_DOMAIN_TIERS = {"cron": "notify", "suggestions": "suggest"}
BUDGET_WINDOW_SECONDS = 24 * 60 * 60


class OfferKind(StrEnum):
    NOTIFY = "notify"
    SUGGEST = "suggest"


class Consent(StrEnum):
    REQUESTED = "requested"
    INITIATED = "initiated"


class Tier(StrEnum):
    OFF = "off"
    SUGGEST = "suggest"
    NOTIFY = "notify"


_TIERS_ALLOWING = {
    OfferKind.NOTIFY: frozenset({Tier.NOTIFY}),
    OfferKind.SUGGEST: frozenset({Tier.SUGGEST, Tier.NOTIFY}),
}


@dataclass(frozen=True, slots=True)
class QuietHours:
    start: time
    end: time

    def contains(self, wall: time) -> bool:
        if self.start <= self.end:
            return self.start <= wall < self.end
        return wall >= self.start or wall < self.end

    def window_end(self, now_local: datetime) -> datetime:
        end_today = datetime.combine(now_local.date(), self.end, tzinfo=now_local.tzinfo)
        if self.start <= self.end or now_local.time() < self.end:
            return end_today
        return datetime.combine(now_local.date() + timedelta(days=1), self.end, tzinfo=now_local.tzinfo)


@dataclass(frozen=True, slots=True)
class Policy:
    enabled: bool
    domain_tiers: Mapping[str, Tier]
    daily_budget: int
    min_gap: timedelta
    quiet: QuietHours | None
    muted: frozenset[str]
    messaging_window: timedelta = field(default=timedelta(minutes=DEFAULT_MESSAGING_WINDOW_MINUTES))


@dataclass(frozen=True, slots=True)
class LogView:
    alerted_last_24h: int
    last_alert_at: float | None


@dataclass(frozen=True, slots=True)
class Verdict:
    land: bool
    alert: bool
    defer_until: float | None
    reason: str


@dataclass(frozen=True, slots=True)
class AppSocket:
    transport_id: str


@dataclass(frozen=True, slots=True)
class Messaging:
    platform: str
    chat_id: str
    thread_id: str | None = None
    user_id: str | None = None
    scope_id: str | None = None
    origin: str = "home"


Channel = AppSocket | Messaging


@dataclass(frozen=True, slots=True)
class Route:
    channel: Channel
    attention: Attention
    last_input_at: float | None
    attention_at: float | None
    device_id: str | None = None
    label: str | None = None


def _parse_clock(value, fallback: str) -> time:
    text = value if isinstance(value, str) else fallback
    try:
        hours, minutes = text.strip().split(":")
        return time(int(hours), int(minutes))
    except (ValueError, AttributeError):
        logger.warning("proactive.quiet_hours: %r is not HH:MM; using %s", value, fallback)
        hours, minutes = fallback.split(":")
        return time(int(hours), int(minutes))


def _quiet_from(raw) -> QuietHours | None:
    if not isinstance(raw, Mapping):
        return None
    start = _parse_clock(raw.get("start"), DEFAULT_QUIET_START)
    end = _parse_clock(raw.get("end"), DEFAULT_QUIET_END)
    return None if start == end else QuietHours(start, end)


def _positive_int(value, fallback: int, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return fallback
    return max(minimum, int(value))


def _tiers_from(raw) -> dict[str, Tier]:
    tiers = {domain: Tier(tier) for domain, tier in DEFAULT_DOMAIN_TIERS.items()}
    if not isinstance(raw, Mapping):
        return tiers
    for domain, tier in raw.items():
        try:
            tiers[str(domain)] = Tier.OFF if tier is False else Tier(str(tier).strip().lower())
        except ValueError:
            logger.warning("proactive.domain_tiers.%s: %r is not off|suggest|notify; ignored", domain, tier)
    return tiers


def load_policy(cfg) -> Policy:
    section = cfg.get("proactive") if isinstance(cfg, Mapping) else None
    section = section if isinstance(section, Mapping) else {}
    muted = section.get("muted_domains")
    return Policy(
        enabled=section.get("enabled") is True,
        domain_tiers=_tiers_from(section.get("domain_tiers")),
        daily_budget=_positive_int(section.get("daily_budget"), DEFAULT_DAILY_BUDGET),
        min_gap=timedelta(minutes=_positive_int(section.get("min_gap_minutes"), DEFAULT_MIN_GAP_MINUTES)),
        quiet=_quiet_from(section["quiet_hours"] if "quiet_hours" in section else {}),
        muted=frozenset(str(d).strip() for d in muted if str(d).strip()) if isinstance(muted, (list, tuple)) else frozenset(),
        messaging_window=timedelta(minutes=_positive_int(
            section.get("messaging_window_minutes"), DEFAULT_MESSAGING_WINDOW_MINUTES, minimum=1)),
    )


def _initiated_verdict(offer, policy: Policy, view: LogView, now: float) -> Verdict | None:
    if not policy.enabled:
        return Verdict(False, False, None, "disabled")
    tier = policy.domain_tiers.get(offer.domain, Tier.OFF)
    if tier not in _TIERS_ALLOWING[offer.kind]:
        return Verdict(False, False, None, "tier_off")
    if view.alerted_last_24h >= policy.daily_budget:
        return Verdict(True, False, None, "budget")
    if view.last_alert_at is not None and now - view.last_alert_at < policy.min_gap.total_seconds():
        return Verdict(True, False, None, "min_gap")
    return None


def judge(offer, policy: Policy, view: LogView, now_local: datetime) -> Verdict:
    if offer.domain in policy.muted:
        return Verdict(True, False, None, "muted")
    if offer.consent is Consent.INITIATED:
        refusal = _initiated_verdict(offer, policy, view, now_local.timestamp())
        if refusal is not None:
            return refusal
    if policy.quiet is not None and policy.quiet.contains(now_local.time()):
        return Verdict(True, False, policy.quiet.window_end(now_local).timestamp(), "quiet_hours")
    return Verdict(True, True, None, "")


def rank(candidates: Iterable[Route]) -> tuple[Route, ...]:
    live = [route for route in candidates if route.attention > Attention.PARKED]
    return tuple(sorted(live, key=lambda r: (-int(r.attention), -(r.last_input_at or 0.0), -(r.attention_at or 0.0))))
