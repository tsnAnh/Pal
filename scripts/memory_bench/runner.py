from __future__ import annotations

import math
import tempfile
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import TypeVar

from scripts.memory_bench.model import (
    Candidate,
    CandidateSpec,
    Event,
    Injection,
    Kind,
    Place,
    Probe,
    Proposal,
    Scenario,
    Source,
    TokenCounter,
    Turn,
)
from scripts.memory_bench.scorer import CaseResult, Observation, score_case

OPERATIONS = ("build", "write", "end_day", "read", "recall")
Value = TypeVar("Value")


@dataclass
class Timings:
    samples: dict[str, list[float]] = field(
        default_factory=lambda: {operation: [] for operation in OPERATIONS}
    )

    def measure(self, operation: str, call: Callable[[], Value]) -> Value:
        started = time.perf_counter()
        value = call()
        self.samples[operation].append((time.perf_counter() - started) * 1000)
        return value


class Replay:
    def __init__(self, candidate: Candidate, timings: Timings):
        self.candidate = candidate
        self.timings = timings
        self._open_day: int | None = None
        self.injected_texts: list[str] = []

    def close_days_before(self, day: int) -> None:
        if self._open_day is None:
            self._open_day = min(0, day)
        while self._open_day < day:
            finished = self._open_day
            self.timings.measure("end_day", lambda: self.candidate.end_day(finished))
            self._open_day += 1

    def feed(self, event: Event) -> None:
        if isinstance(event, Probe):
            self.inject(event)
            return
        self.close_days_before(math.floor(event.at))
        self.timings.measure("write", lambda: self.candidate.write(event))

    def inject(self, probe: Probe) -> Injection:
        self.close_days_before(math.floor(probe.at))
        injection = self.timings.measure("read", lambda: self.candidate.inject(probe))
        self.injected_texts.append(injection.text)
        return injection

    def recall(self, probe: Probe) -> str:
        return self.timings.measure("recall", lambda: self.candidate.recall(probe))


@contextmanager
def attributed(candidate: str, case: str) -> Iterator[None]:
    try:
        yield
    except BaseException as error:
        error.add_note(f"memory bench: candidate {candidate!r} failed on {case}")
        raise


@contextmanager
def session(
    spec: CandidateSpec,
    count_tokens: TokenCounter,
    threshold: float | None,
    case: str,
    timings: Timings | None = None,
) -> Iterator[Replay]:
    recorded = timings if timings is not None else Timings()
    with attributed(spec.name, case), tempfile.TemporaryDirectory(prefix="memory-bench-") as workdir:
        candidate = recorded.measure(
            "build", lambda: spec.build(Path(workdir), count_tokens, threshold)
        )
        try:
            yield Replay(candidate, recorded)
        finally:
            candidate.close()


def run_scenario(
    spec: CandidateSpec,
    scenario: Scenario,
    count_tokens: TokenCounter,
    threshold: float | None,
) -> CaseResult:
    with session(spec, count_tokens, threshold, f"scenario {scenario.id}") as replay:
        for event in scenario.history:
            replay.feed(event)
        injection = replay.inject(scenario.probe)
        recall = replay.recall(scenario.probe)
        candidate = replay.candidate
        observation = Observation(
            injection,
            recall,
            candidate.stored_texts(),
            candidate.losses(),
            candidate.brief_rewrites(),
            tuple(replay.injected_texts[:-1]),
        )
        return score_case(scenario, observation, count_tokens)


def warm_up(spec: CandidateSpec, count_tokens: TokenCounter) -> None:
    place = Place(Source.PAL_APP, "warm-up")
    proposal = Proposal("warm-up", Kind.WORK, "warm up note", "warm-up", 0.9)
    threshold = spec.threshold_grid[0] if spec.threshold_grid else None
    with session(spec, count_tokens, threshold, "warm-up") as replay:
        replay.feed(Turn(0.0, place, "warm-up", "warm up", True, (proposal,)))
        probe = Probe(1.0, place, "warm-up", "warm up", True)
        replay.inject(probe)
        replay.recall(probe)
