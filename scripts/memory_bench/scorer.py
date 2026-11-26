from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from scripts.memory_bench.audit import Exposure, exposure, index_notes
from scripts.memory_bench.model import (
    BRIEF_TOKEN_CAP,
    NOTES_TOKEN_CAP,
    TOTAL_TOKEN_CAP,
    BriefRewrite,
    Category,
    ForbiddenReason,
    Injection,
    Item,
    ItemKind,
    Loss,
    LossReason,
    Scenario,
    Skip,
    SkipReason,
    Split,
    TokenCounter,
    mentions,
)

NO_MATCH = "no_match"
NEVER_OFFERED = "never_offered"
TIERS = ("brief", "notes", "snapshot")
GROUPS = ("store_cap", "injection_cap", "write_rule", "retrieval", "never_offered")
CAP_GROUPS = frozenset({"store_cap", "injection_cap"})
CAP_LOSSES = (LossReason.REJECTED_FULL, LossReason.PRUNED, LossReason.EVICTED_CAP, LossReason.WRITE_LIMIT)
CAUSE_GROUPS: dict[str, str] = {
    **{reason.value: "store_cap" if reason in CAP_LOSSES else "write_rule" for reason in LossReason},
    SkipReason.SLOTS.value: "injection_cap",
    SkipReason.BUDGET.value: "injection_cap",
    SkipReason.BELOW_THRESHOLD.value: "retrieval",
    SkipReason.AUDIENCE.value: "retrieval",
    SkipReason.SENSITIVE.value: "retrieval",
    SkipReason.JOKE_POLICY.value: "retrieval",
    NO_MATCH: "retrieval",
    NEVER_OFFERED: "never_offered",
}
RECALL_LEAK_REASONS = (
    ForbiddenReason.WRONG_AUDIENCE,
    ForbiddenReason.SUPERSEDED,
)
BRIEF_ITEM_KINDS = frozenset({ItemKind.DECISION, ItemKind.COMMITMENT})
TIER_CAPS = (("brief", BRIEF_TOKEN_CAP), ("notes", NOTES_TOKEN_CAP), ("total", TOTAL_TOKEN_CAP))


@dataclass(frozen=True)
class Observation:
    injection: Injection
    recall: str
    stored: tuple[str, ...]
    losses: tuple[Loss, ...]
    rewrites: tuple[BriefRewrite, ...]
    earlier_texts: tuple[str, ...] = ()


@dataclass(frozen=True)
class Miss:
    cause: str
    detail: str = ""


@dataclass(frozen=True)
class ItemOutcome:
    item_id: str
    kind: ItemKind
    stored: bool
    injected: bool
    recalled: bool
    miss: Miss | None
    tier: str | None = None


@dataclass(frozen=True)
class LeakOutcome:
    forbidden_id: str
    reason: ForbiddenReason
    injected: bool
    recalled: bool


@dataclass(frozen=True)
class Tokens:
    brief: int
    notes: int
    snapshot: int
    total: int


@dataclass(frozen=True)
class BriefDrop:
    item_id: str
    kind: ItemKind
    at: float
    channel: str


@dataclass(frozen=True)
class CaseResult:
    scenario_id: str
    category: Category
    split: Split
    covers: str
    items: tuple[ItemOutcome, ...]
    leaks: tuple[LeakOutcome, ...]
    tokens: Tokens
    token_ceiling: int
    violations: tuple[str, ...]
    brief_drops: tuple[BriefDrop, ...]
    rewrites: int
    passed: bool
    injected_text: str
    earlier_injected_texts: tuple[str, ...]
    recall_text: str
    skipped: tuple[Skip, ...]
    exposure: Exposure
    recall_exposure: Exposure

    @property
    def injected_leaks(self) -> tuple[LeakOutcome, ...]:
        return tuple(leak for leak in self.leaks if leak.injected)

    @property
    def over_ceiling(self) -> bool:
        return self.tokens.total > self.token_ceiling


@dataclass(frozen=True)
class LostItem:
    scenario_id: str
    item_id: str
    kind: ItemKind
    cause: str
    group: str
    evicted_by_cap: bool
    detail: str


@dataclass(frozen=True)
class Summary:
    cases: int
    passed: int
    needed_hits: int
    needed_total: int
    leaks: int
    leak_cases: int
    joke_hits: int
    joke_total: int
    recall_hits: int
    recall_leaks: dict[str, int]
    causes: dict[str, dict[str, int]]
    cap_evicted: int
    brief_drops: int | None
    tokens_p50: float | None
    tokens_p95: float | None
    tokens_mean: float | None
    cap_violation_cases: int
    over_ceiling_cases: int
    needed_within_cap: int
    via: dict[str, int]
    leaks_by_reason: dict[str, int]
    exposures: dict[str, int]
    recall_exposures: dict[str, int]


def tier_of(injection: Injection, markers: tuple[str, ...]) -> str | None:
    return next((tier for tier in TIERS if mentions(getattr(injection, tier), markers)), None)


def total_exposure(found: Iterable[Exposure]) -> dict[str, int]:
    entries = tuple(found)
    return {
        "audience": sum(entry.audience for entry in entries),
        "sensitive": sum(entry.sensitive for entry in entries),
    }


def percentile(values: Sequence[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(q * len(ordered) / 100)) - 1]


def explain_miss(markers: tuple[str, ...], observation: Observation) -> Miss:
    if any(mentions(text, markers) for text in observation.stored):
        for skip in observation.injection.skipped:
            if mentions(skip.text, markers):
                detail = "" if skip.score is None else f"score {skip.score:.4f}"
                return Miss(skip.reason.value, detail)
        return Miss(NO_MATCH)
    matching = [loss for loss in observation.losses if mentions(loss.text, markers)]
    if not matching:
        return Miss(NEVER_OFFERED)
    latest = max(reversed(matching), key=lambda loss: loss.at)
    return Miss(latest.reason.value, latest.detail)


def item_outcome(item: Item, observation: Observation) -> ItemOutcome:
    injected = mentions(observation.injection.text, item.markers)
    return ItemOutcome(
        item.id,
        item.kind,
        any(mentions(text, item.markers) for text in observation.stored),
        injected,
        mentions(observation.recall, item.markers),
        None if injected else explain_miss(item.markers, observation),
        tier_of(observation.injection, item.markers),
    )


def count_tiers(injection: Injection, count_tokens: TokenCounter) -> Tokens:
    brief, notes, snapshot, total = (
        count_tokens(part) if part else 0
        for part in (injection.brief, injection.notes, injection.snapshot, injection.text)
    )
    return Tokens(brief, notes, snapshot, total)


def cap_violations(tokens: Tokens) -> tuple[str, ...]:
    return tuple(tier for tier, cap in TIER_CAPS if getattr(tokens, tier) > cap)


def find_brief_drops(items: Iterable[Item], rewrites: Iterable[BriefRewrite]) -> tuple[BriefDrop, ...]:
    tracked = {item.id: item for item in items if item.kind in BRIEF_ITEM_KINDS}
    return tuple(
        BriefDrop(item.id, item.kind, rewrite.at, rewrite.place.channel)
        for rewrite in rewrites
        for item in tracked.values()
        if mentions(rewrite.before, item.markers) and not mentions(rewrite.after, item.markers)
    )


def score_case(scenario: Scenario, observation: Observation, count_tokens: TokenCounter) -> CaseResult:
    items = tuple(item_outcome(item, observation) for item in scenario.expected)
    leaks = tuple(
        LeakOutcome(
            forbidden.id,
            forbidden.reason,
            mentions(observation.injection.text, forbidden.markers),
            mentions(observation.recall, forbidden.markers),
        )
        for forbidden in scenario.forbidden
    )
    tokens = count_tiers(observation.injection, count_tokens)
    violations = cap_violations(tokens)
    written = index_notes(scenario.history)
    passed = (
        all(item.injected for item in items)
        and not any(leak.injected for leak in leaks)
        and tokens.total <= scenario.token_ceiling
        and not violations
    )
    return CaseResult(
        scenario.id,
        scenario.category,
        scenario.split,
        scenario.covers,
        items,
        leaks,
        tokens,
        scenario.token_ceiling,
        violations,
        find_brief_drops(scenario.expected, observation.rewrites),
        len(observation.rewrites),
        passed,
        observation.injection.text,
        observation.earlier_texts,
        observation.recall,
        observation.injection.skipped,
        exposure(written, observation.injection.text, scenario.probe, injected=True),
        exposure(written, observation.recall, scenario.probe, injected=False),
    )


def tally_causes(misses: Iterable[Miss]) -> dict[str, dict[str, int]]:
    tally: dict[str, dict[str, int]] = {}
    for miss in misses:
        group = tally.setdefault(CAUSE_GROUPS[miss.cause], {})
        group[miss.cause] = group.get(miss.cause, 0) + 1
    return tally


def lost_needed(results: Iterable[CaseResult]) -> tuple[LostItem, ...]:
    return tuple(
        LostItem(
            result.scenario_id,
            item.item_id,
            item.kind,
            item.miss.cause,
            CAUSE_GROUPS[item.miss.cause],
            CAUSE_GROUPS[item.miss.cause] in CAP_GROUPS,
            item.miss.detail,
        )
        for result in results
        for item in result.items
        if item.kind is not ItemKind.JOKE and item.miss is not None
    )


def summarize(results: Sequence[CaseResult]) -> Summary:
    needed = [item for result in results for item in result.items if item.kind is not ItemKind.JOKE]
    jokes = [item for result in results for item in result.items if item.kind is ItemKind.JOKE]
    leaks = [leak for result in results for leak in result.leaks]
    lost = lost_needed(results)
    totals = [result.tokens.total for result in results]
    rewrites = sum(result.rewrites for result in results)
    return Summary(
        cases=len(results),
        passed=sum(result.passed for result in results),
        needed_hits=sum(item.injected for item in needed),
        needed_total=len(needed),
        leaks=sum(leak.injected for leak in leaks),
        leak_cases=sum(bool(result.injected_leaks) for result in results),
        joke_hits=sum(item.injected for item in jokes),
        joke_total=len(jokes),
        recall_hits=sum(item.recalled for item in needed),
        recall_leaks={
            reason.value: sum(leak.recalled and leak.reason is reason for leak in leaks)
            for reason in RECALL_LEAK_REASONS
        },
        causes=tally_causes(item.miss for item in needed if item.miss is not None),
        cap_evicted=sum(entry.evicted_by_cap for entry in lost),
        brief_drops=sum(len(result.brief_drops) for result in results) if rewrites else None,
        tokens_p50=percentile(totals, 50),
        tokens_p95=percentile(totals, 95),
        tokens_mean=sum(totals) / len(totals) if totals else None,
        cap_violation_cases=sum(bool(result.violations) for result in results),
        over_ceiling_cases=sum(result.over_ceiling for result in results),
        needed_within_cap=sum(
            item.injected
            for result in results
            if not result.violations
            for item in result.items
            if item.kind is not ItemKind.JOKE
        ),
        via={tier: sum(item.tier == tier for item in needed) for tier in TIERS},
        leaks_by_reason={
            reason.value: count
            for reason in ForbiddenReason
            if (count := sum(leak.injected and leak.reason is reason for leak in leaks))
        },
        exposures=total_exposure(result.exposure for result in results),
        recall_exposures=total_exposure(result.recall_exposure for result in results),
    )
