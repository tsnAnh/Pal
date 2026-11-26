from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from scripts.memory_bench.model import CandidateSpec, Scenario, Split, TokenCounter
from scripts.memory_bench.runner import run_scenario
from scripts.memory_bench.scorer import summarize


@dataclass(frozen=True)
class CurvePoint:
    threshold: float
    leaks: int
    needed_hits: int
    joke_hits: int
    mean_tokens: float


@dataclass(frozen=True)
class Tuning:
    threshold: float | None
    curve: tuple[CurvePoint, ...] = ()


def preference(point: CurvePoint) -> tuple[int, int, int, float]:
    return point.leaks, -point.needed_hits, -point.joke_hits, point.mean_tokens


def choose(curve: Sequence[CurvePoint]) -> float:
    best = min(map(preference, curve))
    tied = sorted(point.threshold for point in curve if preference(point) == best)
    return tied[(len(tied) - 1) // 2]


def evaluate(
    spec: CandidateSpec,
    scenarios: Sequence[Scenario],
    count_tokens: TokenCounter,
    threshold: float,
) -> CurvePoint:
    summary = summarize(
        [run_scenario(spec, scenario, count_tokens, threshold) for scenario in scenarios]
    )
    return CurvePoint(
        threshold, summary.leaks, summary.needed_hits, summary.joke_hits, summary.tokens_mean or 0.0
    )


def tune(spec: CandidateSpec, scenarios: Sequence[Scenario], count_tokens: TokenCounter) -> Tuning:
    if not spec.threshold_grid:
        return Tuning(None)
    dev = tuple(scenario for scenario in scenarios if scenario.split is Split.DEV)
    if not dev:
        raise ValueError(f"candidate {spec.name!r} has a threshold grid but there is no dev scenario")
    curve = tuple(evaluate(spec, dev, count_tokens, value) for value in spec.threshold_grid)
    return Tuning(choose(curve), curve)
