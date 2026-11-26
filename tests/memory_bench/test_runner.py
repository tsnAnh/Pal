from __future__ import annotations

import socket
from pathlib import Path

import pytest

from scripts.memory_bench import network_guard, pipeline, report, runner, tuning
from scripts.memory_bench.model import (
    BriefRewrite,
    CandidateSpec,
    Category,
    History,
    Injection,
    Item,
    ItemKind,
    Kind,
    Loss,
    LossReason,
    Place,
    Probe,
    Proposal,
    Question,
    Scenario,
    Source,
    Split,
    Turn,
    Load,
)

PLACE = Place(Source.SLACK, "ops")


def words(text: str) -> int:
    return len(text.split())


class FakeCandidate:
    def __init__(self, workdir: Path, threshold: float | None, journal: list, keep: int = 2):
        self.workdir = workdir
        self.threshold = threshold
        self.journal = journal
        self.keep = keep
        self.notes: list[str] = []
        self.lost: list[Loss] = []
        self.rewrites: list[BriefRewrite] = []

    def write(self, turn):
        self.journal.append(("write", turn.at))
        for proposal in turn.proposals:
            self.notes.append(proposal.text)
        while len(self.notes) > self.keep:
            evicted = self.notes.pop(0)
            self.lost.append(Loss(evicted, LossReason.EVICTED_CAP, turn.at, "fake cap"))
            self.rewrites.append(BriefRewrite(turn.at, turn.place, evicted, ""))

    def end_day(self, day):
        self.journal.append(("end_day", day))

    def inject(self, probe):
        self.journal.append(("inject", probe.at))
        if self.threshold is not None and self.threshold > 0.5:
            return Injection()
        return Injection(notes="\n".join(self.notes))

    def recall(self, query):
        self.journal.append(("recall", query.at))
        return "\n".join(self.notes)

    def stored_texts(self):
        return tuple(self.notes)

    def losses(self):
        return tuple(self.lost)

    def brief_rewrites(self):
        return tuple(self.rewrites)

    def close(self):
        self.journal.append(("close", str(self.workdir)))


def fake_spec(name="fake", journal=None, grid=(), keep=2) -> CandidateSpec:
    log = journal if journal is not None else []

    def build(workdir, count_tokens, threshold):
        log.append(("build", threshold))
        return FakeCandidate(workdir, threshold, log, keep)

    return CandidateSpec(name, "fake candidate", build, threshold_grid=grid)


def turn(at, text, kind=Kind.WORK) -> Turn:
    return Turn(at, PLACE, "sam", text, proposals=(Proposal(text, kind, text, "t", 0.9),))


def scenario(ident, split, history, probe_at, marker) -> Scenario:
    return Scenario(
        ident,
        Category.NEEDED,
        split,
        "x",
        tuple(history),
        Probe(probe_at, PLACE, "sam", "q"),
        (Item(marker, ItemKind.DECISION, (marker,)),),
        (),
        100,
    )


def build_history(seed, salience, load=Load.TYPICAL) -> History:
    turns = (turn(0.5, "alpha"), turn(20.5, "bravo"), turn(28.5, "charlie"))
    questions = tuple(
        Question(Probe(30.5, PLACE, "sam", word), Item(word, ItemKind.DECISION, (word,)), said_at)
        for word, said_at in (("alpha", 0.5), ("bravo", 20.5), ("charlie", 28.5))
    )
    return History(turns, questions, 30)


def test_end_day_runs_once_per_finished_day_including_empty_days():
    journal: list = []
    history = [turn(0.2, "alpha"), turn(0.7, "bravo"), Probe(3.1, PLACE, "sam", "q")]
    case = scenario("gap", Split.DEV, history, 5.0, "alpha")
    result = runner.run_scenario(fake_spec(journal=journal), case, words, None)
    assert result.earlier_injected_texts == ("alpha\nbravo",)
    kinds = [entry[:2] for entry in journal if entry[0] not in ("build", "close")]
    assert kinds == [
        ("write", 0.2),
        ("write", 0.7),
        ("end_day", 0),
        ("end_day", 1),
        ("end_day", 2),
        ("inject", 3.1),
        ("end_day", 3),
        ("end_day", 4),
        ("inject", 5.0),
        ("recall", 5.0),
    ]


def test_workdir_is_closed_and_removed():
    journal: list = []
    case = scenario("one", Split.DEV, [turn(0.1, "alpha")], 0.2, "alpha")
    result = runner.run_scenario(fake_spec(journal=journal), case, words, None)
    assert result.passed
    (closed,) = [entry for entry in journal if entry[0] == "close"]
    assert not Path(closed[1]).exists()


def test_candidate_failure_is_loud_and_named():
    class Broken(FakeCandidate):
        def inject(self, probe):
            raise KeyError("boom")

    spec = CandidateSpec("broken", "x", lambda workdir, count, threshold: Broken(workdir, threshold, []))
    case = scenario("case-7", Split.DEV, [], 0.2, "alpha")
    with pytest.raises(KeyError) as failure:
        runner.run_scenario(spec, case, words, None)
    notes = " ".join(failure.value.__notes__)
    assert "broken" in notes and "case-7" in notes


def test_tuning_never_runs_the_test_split():
    journal: list = []
    seen = [
        scenario("dev", Split.DEV, [turn(0.1, "alpha")], 0.2, "alpha"),
        scenario("held-out", Split.TEST, [turn(9.1, "bravo")], 9.2, "bravo"),
    ]
    tuned = tuning.tune(fake_spec(journal=journal, grid=(0.1, 0.3, 0.9)), seen, words)
    assert not [entry for entry in journal if entry[1] in (9.1, 9.2)]
    assert [point.threshold for point in tuned.curve] == [0.1, 0.3, 0.9]
    assert tuned.threshold == 0.1


@pytest.mark.parametrize(
    ("rows", "chosen"),
    [
        ([(0.1, 1, 9, 9, 1.0), (0.2, 0, 1, 0, 50.0)], 0.2),
        ([(0.1, 0, 1, 0, 1.0), (0.2, 0, 2, 0, 50.0)], 0.2),
        ([(0.1, 0, 2, 0, 1.0), (0.2, 0, 2, 1, 50.0)], 0.2),
        ([(0.1, 0, 2, 1, 60.0), (0.2, 0, 2, 1, 50.0)], 0.2),
        ([(0.1, 0, 2, 1, 5.0), (0.2, 0, 2, 1, 5.0), (0.3, 0, 2, 1, 5.0), (0.4, 1, 2, 1, 5.0)], 0.2),
    ],
)
def test_threshold_choice_order(rows, chosen):
    assert tuning.choose([tuning.CurvePoint(*row) for row in rows]) == chosen


def test_fake_candidate_runs_end_to_end():
    journal: list = []
    scenarios = (
        scenario("dev", Split.DEV, [turn(0.1, "alpha")], 0.2, "alpha"),
        scenario("test", Split.TEST, [turn(0.1, "bravo")], 1.2, "bravo"),
    )
    plan = pipeline.Plan(
        specs=(fake_spec(journal=journal, grid=(0.2, 0.8)), fake_spec("plain", keep=9)),
        scenarios=scenarios,
        build_history=build_history,
        count_tokens=words,
        seeds=2,
        repeats=2,
    )
    payload = pipeline.run_plan(plan, lambda message: None)
    assert payload["candidates"]["fake"]["threshold"] == 0.2
    assert payload["candidates"]["plain"]["threshold"] is None
    assert payload["scenarios"]["fake"]["summary"]["all"]["needed_hits"] == 2
    assert set(payload["scenarios"]["fake"]["summary"]) == {"dev", "test", "all"}
    simulated = payload["simulation"]["fake"]["typical/informative"]
    assert "at_cap/informative" in payload["simulation"]["fake"]
    assert simulated["language"] == {"same": {"injected": 4, "total": 6}, "cross": {"injected": 0, "total": 0}}
    assert simulated["buckets"]["15-30"]["survived"]["count"] == 0
    assert simulated["buckets"]["0-7"]["injected"] == {
        "count": 2, "total": 2, "pct": 100.0, "median_pct": 100.0, "min_pct": 100.0, "max_pct": 100.0,
    }
    assert simulated["buckets"]["8-14"]["recalled"]["count"] == 2
    assert simulated["causes"] == {"store_cap": {"evicted_store_cap": 2}}
    assert simulated["via"] == {"brief": 0, "notes": 4, "snapshot": 0}
    assert simulated["needed_within_cap"] == 4
    assert set(simulated["exposures"]) == {"audience", "sensitive"}
    assert simulated["brief_drops"] == 2
    assert simulated["stored_notes"]["median"] == 2
    assert payload["simulation"]["plain"]["typical/flat"]["brief_drops"] is None
    assert payload["latency"]["plain"]["history"]["write"]["p50"]["median"] >= 0
    payload["skipped"] = [{"name": "ghost", "reason": "not installed"}]
    text = report.render(payload)
    for expected in ("fake", "plain", "ghost", "evicted_store_cap", "0.8"):
        assert expected in text


def test_split_filter_and_skips():
    journal: list = []
    scenarios = (
        scenario("dev", Split.DEV, [turn(0.1, "alpha")], 0.2, "alpha"),
        scenario("held-out", Split.TEST, [turn(9.1, "bravo")], 9.2, "bravo"),
    )
    plan = pipeline.Plan(
        specs=(fake_spec(journal=journal),),
        scenarios=scenarios,
        build_history=build_history,
        count_tokens=words,
        split="dev",
        skip_sim=True,
        skip_latency=True,
    )
    payload = pipeline.run_plan(plan, lambda message: None)
    assert set(payload["scenarios"]["fake"]["summary"]) == {"dev"}
    assert (payload["simulation"], payload["latency"]) == ({}, {})
    assert not [entry for entry in journal if entry[1] in (9.1, 9.2)]
    assert "dev" in report.render(payload)


def test_network_guard_refuses_remote_and_allows_loopback():
    original = socket.getaddrinfo
    with network_guard.network_blocked() as guard:
        with pytest.raises(network_guard.NetworkBlocked):
            socket.getaddrinfo("example.com", 443)
        with socket.socket() as outbound, pytest.raises(network_guard.NetworkBlocked):
            outbound.connect(("192.0.2.1", 9))
        with socket.socket() as outbound, pytest.raises(network_guard.NetworkBlocked):
            outbound.connect_ex(("192.0.2.1", 9))
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            with socket.create_connection(server.getsockname(), timeout=5):
                pass
    assert guard.attempts == 3
    assert socket.getaddrinfo is original
