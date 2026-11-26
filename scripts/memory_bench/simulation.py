from __future__ import annotations

import itertools
import math
import statistics
from collections.abc import Callable, Sequence
from dataclasses import dataclass

from scripts.memory_bench.audit import Exposure, NoteIndex, exposure, index_notes
from scripts.memory_bench.model import (
    BRIEF_TOKEN_CAP,
    TOTAL_TOKEN_CAP,
    CandidateSpec,
    History,
    ItemKind,
    Load,
    Question,
    SalienceMode,
    SkipReason,
    TokenCounter,
    mentions,
    vietnamese,
)
from scripts.memory_bench.runner import Replay, attributed, session
from scripts.memory_bench.scorer import (
    TIERS,
    BriefDrop,
    Miss,
    Observation,
    Tokens,
    count_tiers,
    find_brief_drops,
    item_outcome,
    percentile,
    tally_causes,
    total_exposure,
)

AGE_BUCKETS: tuple[tuple[str, float], ...] = (
    ("0-7", 7),
    ("8-14", 14),
    ("15-30", 30),
    ("31+", math.inf),
)
MEASURES = ("survived", "injected", "recalled")
BRIEF_BOUND_TOKENS = 0.9 * BRIEF_TOKEN_CAP
LANGUAGE_PAIRS = (("same", True), ("cross", False))
HistoryBuilder = Callable[[int, SalienceMode, Load], History]


@dataclass(frozen=True)
class Answer:
    item_id: str
    kind: ItemKind
    bucket: str
    survived: bool
    injected: bool
    recalled: bool
    miss: Miss | None
    leaks: tuple[str, ...]
    tokens: Tokens
    brief_bound: bool
    budget_skip: bool
    slot_skip: bool
    injected_text: str
    same_language: bool
    tier: str | None
    exposure: Exposure
    recall_exposure: Exposure


@dataclass(frozen=True)
class SeedRun:
    seed: int
    answers: tuple[Answer, ...]
    stored_notes: int
    brief_drops: tuple[BriefDrop, ...]
    rewrites: int


def age_bucket(age: float) -> str:
    days = max(0, math.floor(age))
    return next(name for name, upper in AGE_BUCKETS if days <= upper)


def note_text(history: History, markers: tuple[str, ...]) -> str:
    return next(
        (
            proposal.text
            for turn in history.turns
            for proposal in turn.proposals
            if mentions(proposal.text, markers)
        ),
        "",
    )


def answer(
    replay: Replay, question: Question, history: History, written: NoteIndex, count_tokens: TokenCounter
) -> Answer:
    injection = replay.inject(question.probe)
    recall = replay.recall(question.probe)
    candidate = replay.candidate
    observation = Observation(injection, recall, candidate.stored_texts(), candidate.losses(), ())
    outcome = item_outcome(question.item, observation)
    tokens = count_tiers(injection, count_tokens)
    reasons = {skip.reason for skip in injection.skipped}
    return Answer(
        question.item.id,
        question.item.kind,
        age_bucket(history.last_day - question.said_at),
        outcome.stored,
        outcome.injected,
        outcome.recalled,
        outcome.miss,
        tuple(
            forbidden.id
            for forbidden in question.forbidden
            if mentions(injection.text, forbidden.markers)
        ),
        tokens,
        tokens.brief >= BRIEF_BOUND_TOKENS,
        SkipReason.BUDGET in reasons,
        SkipReason.SLOTS in reasons,
        injection.text,
        vietnamese(question.probe.text) == vietnamese(note_text(history, question.item.markers)),
        outcome.tier,
        exposure(written, injection.text, question.probe, injected=True),
        exposure(written, recall, question.probe, injected=False),
    )


def run_history(
    spec: CandidateSpec,
    history: History,
    seed: int,
    count_tokens: TokenCounter,
    threshold: float | None,
    case: str,
) -> SeedRun:
    with session(spec, count_tokens, threshold, case) as replay:
        for turn in history.turns:
            replay.feed(turn)
        replay.close_days_before(history.last_day + 1)
        answers = []
        written = index_notes(history.turns)
        for question in history.questions:
            with attributed(spec.name, f"question {question.item.id}"):
                answers.append(answer(replay, question, history, written, count_tokens))
        rewrites = replay.candidate.brief_rewrites()
        return SeedRun(
            seed,
            tuple(answers),
            len(replay.candidate.stored_texts()),
            find_brief_drops((question.item for question in history.questions), rewrites),
            len(rewrites),
        )


def bucket_measure(runs: Sequence[SeedRun], bucket: str, measure: str, jokes: bool) -> dict:
    per_seed = [
        [
            bool(getattr(entry, measure))
            for entry in run.answers
            if entry.bucket == bucket and (entry.kind is ItemKind.JOKE) == jokes
        ]
        for run in runs
    ]
    shares = [100 * sum(flags) / len(flags) for flags in per_seed if flags]
    count = sum(map(sum, per_seed))
    total = sum(map(len, per_seed))
    return {
        "count": count,
        "total": total,
        "pct": 100 * count / total if total else None,
        "median_pct": statistics.median(shares) if shares else None,
        "min_pct": min(shares, default=None),
        "max_pct": max(shares, default=None),
    }


def bucket_table(runs: Sequence[SeedRun], jokes: bool) -> dict:
    table = {
        bucket: {measure: bucket_measure(runs, bucket, measure, jokes) for measure in MEASURES}
        for bucket, _ in AGE_BUCKETS
    }
    return {bucket: row for bucket, row in table.items() if row["survived"]["total"]}


def spread(values: Sequence[float]) -> dict:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def language_split(answers: Sequence[Answer]) -> dict:
    needed = [entry for entry in answers if entry.kind is not ItemKind.JOKE]
    return {
        name: {
            "injected": sum(entry.injected for entry in needed if entry.same_language is same),
            "total": sum(entry.same_language is same for entry in needed),
        }
        for name, same in LANGUAGE_PAIRS
    }


def summarize_mode(runs: Sequence[SeedRun]) -> dict:
    answers = [entry for run in runs for entry in run.answers]
    totals = [entry.tokens.total for entry in answers]
    rewrites = sum(run.rewrites for run in runs)
    return {
        "seeds": len(runs),
        "questions": len(answers),
        "buckets": bucket_table(runs, jokes=False),
        "joke_buckets": bucket_table(runs, jokes=True),
        "language": language_split(answers),
        "via": {
            tier: sum(entry.tier == tier for entry in answers if entry.kind is not ItemKind.JOKE)
            for tier in TIERS
        },
        "needed_within_cap": sum(
            entry.injected and entry.tokens.total <= TOTAL_TOKEN_CAP
            for entry in answers
            if entry.kind is not ItemKind.JOKE
        ),
        "exposures": total_exposure(entry.exposure for entry in answers),
        "recall_exposures": total_exposure(entry.recall_exposure for entry in answers),
        "causes": tally_causes(
            entry.miss for entry in answers if entry.miss and entry.kind is not ItemKind.JOKE
        ),
        "brief_drops": sum(len(run.brief_drops) for run in runs) if rewrites else None,
        "stored_notes": spread([run.stored_notes for run in runs]),
        "tokens": {
            "p50": percentile(totals, 50),
            "p95": percentile(totals, 95),
            "max": max(totals, default=None),
        },
        "caps_bound": {
            "brief_at_90pct": sum(entry.brief_bound for entry in answers),
            "skipped_for_budget": sum(entry.budget_skip for entry in answers),
            "skipped_for_slots": sum(entry.slot_skip for entry in answers),
        },
        "leaks": sum(len(entry.leaks) for entry in answers),
        "leak_probes": sum(bool(entry.leaks) for entry in answers),
        "runs": list(runs),
    }


def simulate(
    specs: Sequence[tuple[CandidateSpec, float | None]],
    build_history: HistoryBuilder,
    seeds: int,
    count_tokens: TokenCounter,
    progress: Callable[[str], None],
) -> dict:
    results: dict[str, dict] = {spec.name: {} for spec, _ in specs}
    for load, mode in itertools.product(Load, SalienceMode):
        key = f"{load.value}/{mode.value}"
        histories = [build_history(seed, mode, load) for seed in range(seeds)]
        for spec, threshold in specs:
            runs = []
            for seed, history in enumerate(histories):
                progress(f"simulation {spec.name} {key} seed {seed}")
                case = f"simulation {key} seed {seed}"
                runs.append(run_history(spec, history, seed, count_tokens, threshold, case))
            results[spec.name][key] = summarize_mode(runs)
    return results
