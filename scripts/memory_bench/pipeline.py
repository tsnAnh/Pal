from __future__ import annotations

import json
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, is_dataclass
from enum import Enum

from scripts.memory_bench import latency, simulation
from scripts.memory_bench.model import CandidateSpec, Load, SalienceMode, Scenario, Split, TokenCounter
from scripts.memory_bench.runner import run_scenario
from scripts.memory_bench.scorer import lost_needed, summarize
from scripts.memory_bench.tuning import tune

ALL_SPLITS = "all"
SPLIT_CHOICES = (*(split.value for split in Split), ALL_SPLITS)
Progress = Callable[[str], None]


@dataclass(frozen=True)
class Plan:
    specs: tuple[CandidateSpec, ...]
    scenarios: tuple[Scenario, ...]
    build_history: simulation.HistoryBuilder
    count_tokens: TokenCounter
    split: str = ALL_SPLITS
    seeds: int = 5
    repeats: int = 5
    skip_sim: bool = False
    skip_latency: bool = False


def encode(value: object) -> object:
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value) and not isinstance(value, type):
        return asdict(value)
    raise TypeError(f"cannot write {type(value).__name__} to the results file")


def selected_scenarios(plan: Plan) -> tuple[Scenario, ...]:
    chosen = tuple(
        scenario
        for scenario in plan.scenarios
        if plan.split in (ALL_SPLITS, scenario.split.value)
    )
    if not chosen:
        raise ValueError(f"no scenario in split {plan.split!r}")
    return chosen


def scenario_report(
    spec: CandidateSpec,
    scenarios: Sequence[Scenario],
    plan: Plan,
    threshold: float | None,
    progress: Progress,
) -> dict:
    cases = []
    for scenario in scenarios:
        progress(f"scenario {spec.name} {scenario.id}")
        cases.append(run_scenario(spec, scenario, plan.count_tokens, threshold))
    splits = SPLIT_CHOICES if plan.split == ALL_SPLITS else (plan.split,)
    subsets = {
        name: [case for case in cases if name in (ALL_SPLITS, case.split.value)] for name in splits
    }
    return {
        "summary": {name: summarize(subset) for name, subset in subsets.items() if subset},
        "lost_needed": lost_needed(cases),
        "cases": cases,
    }


def run_plan(plan: Plan, progress: Progress) -> dict:
    scenarios = selected_scenarios(plan)
    tunings = {}
    for spec in plan.specs:
        if spec.threshold_grid:
            progress(f"tuning {spec.name} on dev over {len(spec.threshold_grid)} thresholds")
        tunings[spec.name] = tune(spec, plan.scenarios, plan.count_tokens)
    tuned = tuple((spec, tunings[spec.name].threshold) for spec in plan.specs)
    payload: dict = {
        "plan": {
            "split": plan.split,
            "seeds": plan.seeds,
            "repeats": plan.repeats,
            "scenarios": [scenario.id for scenario in scenarios],
        },
        "candidates": {
            spec.name: {"description": spec.description, **asdict(tunings[spec.name])}
            for spec in plan.specs
        },
        "scenarios": {
            spec.name: scenario_report(spec, scenarios, plan, threshold, progress)
            for spec, threshold in tuned
        },
        "simulation": {},
        "latency": {},
    }
    if not plan.skip_sim:
        payload["simulation"] = simulation.simulate(
            tuned, plan.build_history, plan.seeds, plan.count_tokens, progress
        )
    if not plan.skip_latency:
        payload["latency"] = latency.measure(
            tuned,
            scenarios,
            plan.build_history(0, SalienceMode.INFORMATIVE, Load.AT_CAP),
            plan.count_tokens,
            plan.repeats,
            progress,
        )
    return json.loads(json.dumps(payload, default=encode))
