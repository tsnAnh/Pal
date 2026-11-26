from __future__ import annotations

import statistics
from collections.abc import Callable, Sequence

from scripts.memory_bench.model import CandidateSpec, History, Scenario, TokenCounter
from scripts.memory_bench.runner import OPERATIONS, Timings, session
from scripts.memory_bench.scorer import percentile

WORKLOADS = ("scenarios", "history")


def time_scenarios(
    spec: CandidateSpec,
    scenarios: Sequence[Scenario],
    count_tokens: TokenCounter,
    threshold: float | None,
) -> Timings:
    timings = Timings()
    for scenario in scenarios:
        case = f"latency scenario {scenario.id}"
        with session(spec, count_tokens, threshold, case, timings) as replay:
            for event in scenario.history:
                replay.feed(event)
            replay.inject(scenario.probe)
            replay.recall(scenario.probe)
    return timings


def time_history(
    spec: CandidateSpec,
    history: History,
    count_tokens: TokenCounter,
    threshold: float | None,
) -> Timings:
    timings = Timings()
    with session(spec, count_tokens, threshold, "latency history", timings) as replay:
        for turn in history.turns:
            replay.feed(turn)
        replay.close_days_before(history.last_day + 1)
        for question in history.questions:
            replay.inject(question.probe)
            replay.recall(question.probe)
    return timings


def across_repeats(passes: Sequence[Timings], operation: str) -> dict:
    result: dict = {"samples_per_repeat": len(passes[0].samples[operation])}
    for name, q in (("p50", 50), ("p95", 95)):
        values = [percentile(entry.samples[operation], q) for entry in passes]
        measured = [value for value in values if value is not None]
        result[name] = (
            {"median": statistics.median(measured), "min": min(measured), "max": max(measured)}
            if measured
            else None
        )
    return result


def measure(
    specs: Sequence[tuple[CandidateSpec, float | None]],
    scenarios: Sequence[Scenario],
    history: History,
    count_tokens: TokenCounter,
    repeats: int,
    progress: Callable[[str], None],
) -> dict:
    passes: dict[str, dict[str, list[Timings]]] = {
        spec.name: {workload: [] for workload in WORKLOADS} for spec, _ in specs
    }
    for repeat in range(repeats):
        ordered = specs if repeat % 2 == 0 else tuple(reversed(specs))
        for spec, threshold in ordered:
            progress(f"latency repeat {repeat + 1}/{repeats} {spec.name}")
            passes[spec.name]["scenarios"].append(
                time_scenarios(spec, scenarios, count_tokens, threshold)
            )
            passes[spec.name]["history"].append(
                time_history(spec, history, count_tokens, threshold)
            )
    return {
        name: {
            workload: {operation: across_repeats(entries, operation) for operation in OPERATIONS}
            for workload, entries in workloads.items()
        }
        for name, workloads in passes.items()
    }
