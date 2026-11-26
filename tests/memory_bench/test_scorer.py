from __future__ import annotations

import pytest

from scripts.memory_bench import scorer
from scripts.memory_bench.model import (
    BRIEF_TOKEN_CAP,
    BriefRewrite,
    Category,
    Forbidden,
    ForbiddenReason,
    Injection,
    Item,
    ItemKind,
    Loss,
    LossReason,
    Place,
    Probe,
    Scenario,
    Skip,
    SkipReason,
    Source,
    Split,
)

PLACE = Place(Source.SLACK, "ops")


def words(text: str) -> int:
    return len(text.split())


def scenario(expected=(), forbidden=(), ceiling=100, split=Split.DEV, ident="s1") -> Scenario:
    return Scenario(
        id=ident,
        category=Category.NEEDED,
        split=split,
        covers="x",
        history=(),
        probe=Probe(2.0, PLACE, "sam", "what now"),
        expected=tuple(expected),
        forbidden=tuple(forbidden),
        token_ceiling=ceiling,
    )


def fact(ident="db", *markers, kind=ItemKind.FACT) -> Item:
    return Item(ident, kind, markers or (ident,))


def observe(injection=Injection(), recall="", stored=(), losses=(), rewrites=()):
    return scorer.Observation(injection, recall, tuple(stored), tuple(losses), tuple(rewrites))


def score(case, observation):
    return scorer.score_case(case, observation, words)


def test_needed_item_in_injection_is_hit_and_case_passes():
    result = score(scenario([fact("postgres")]), observe(Injection(notes="we use Postgres")))
    summary = scorer.summarize([result])
    assert (summary.needed_hits, summary.needed_total, summary.leaks, result.passed) == (1, 1, 0, True)


def test_missing_needed_item_is_not_a_hit_and_fails_case():
    result = score(scenario([fact("postgres")]), observe(Injection(notes="nothing here")))
    summary = scorer.summarize([result])
    assert (summary.needed_hits, summary.needed_total, result.passed) == (0, 1, False)


def test_leak_is_detected_and_fails_case_even_with_all_hits():
    bad = Forbidden("secret", ForbiddenReason.SENSITIVE, ("salary",))
    result = score(
        scenario([fact("postgres")], [bad]),
        observe(Injection(notes="postgres and the Salary figure")),
    )
    summary = scorer.summarize([result])
    assert (summary.leaks, summary.leak_cases, summary.needed_hits, result.passed) == (1, 1, 1, False)


def test_superseded_old_value_beside_new_fails():
    old = Forbidden("old", ForbiddenReason.SUPERSEDED, ("friday",))
    result = score(
        scenario([fact("monday")], [old]),
        observe(Injection(notes="ship monday", brief="ship friday")),
    )
    assert not result.passed
    assert scorer.summarize([result]).leaks == 1


@pytest.mark.parametrize(
    ("stored", "skipped", "losses", "cause", "group"),
    [
        ((), (), (Loss("postgres note", LossReason.EVICTED_CAP, 1.0, "cap 500"),), "evicted_store_cap", "store"),
        (
            (),
            (),
            (Loss("postgres a", LossReason.MERGED, 1.0), Loss("postgres b", LossReason.EXPIRED, 2.0)),
            "expired",
            "store",
        ),
        ((), (), (Loss("unrelated", LossReason.EXPIRED, 1.0),), "never_offered", "never_offered"),
        (("postgres",), (), (Loss("postgres", LossReason.MERGED, 1.0),), "no_match", "retrieval"),
        (("postgres",), (Skip("postgres", SkipReason.BELOW_THRESHOLD, 0.1),), (), "below_threshold", "retrieval"),
        (("postgres",), (Skip("postgres", SkipReason.BUDGET),), (), "token_budget", "injection_cap"),
        (("postgres",), (Skip("other", SkipReason.SLOTS),), (), "no_match", "retrieval"),
    ],
)
def test_every_miss_gets_exactly_one_cause(stored, skipped, losses, cause, group):
    result = score(
        scenario([fact("postgres")]),
        observe(Injection(skipped=skipped), stored=stored, losses=losses),
    )
    (lost,) = scorer.lost_needed([result])
    assert (lost.cause, lost.group) == (cause, group)
    summary = scorer.summarize([result])
    assert summary.causes == {group: {cause: 1}}
    assert summary.cap_evicted == int(group in ("store", "injection_cap"))
    assert lost.evicted_by_cap == (group in ("store", "injection_cap"))


def test_loss_detail_is_listed():
    result = score(
        scenario([fact("postgres")]),
        observe(losses=(Loss("postgres", LossReason.WRITE_LIMIT, 1.0, "third write"),)),
    )
    (lost,) = scorer.lost_needed([result])
    assert (lost.scenario_id, lost.item_id, lost.kind.value, lost.detail) == (
        "s1",
        "postgres",
        "fact",
        "third write",
    )


def test_joke_never_enters_headline_or_lost_list():
    case = scenario([fact("banana", kind=ItemKind.JOKE), fact("postgres")])
    result = score(case, observe(Injection(notes="postgres")))
    summary = scorer.summarize([result])
    assert (summary.needed_hits, summary.needed_total) == (1, 1)
    assert (summary.joke_hits, summary.joke_total) == (0, 1)
    assert scorer.lost_needed([result]) == ()
    assert summary.causes == {}
    assert not result.passed


def test_forbidden_joke_counts_as_leak():
    joke = Forbidden("pun", ForbiddenReason.INCIDENT, ("banana",))
    result = score(scenario(forbidden=[joke]), observe(Injection(notes="banana")))
    assert scorer.summarize([result]).leaks == 1
    assert not result.passed


def test_recall_column_and_recall_leaks_by_reason():
    forbidden = [
        Forbidden("a", ForbiddenReason.WRONG_AUDIENCE, ("alpha",)),
        Forbidden("b", ForbiddenReason.SENSITIVE, ("bravo",)),
        Forbidden("c", ForbiddenReason.IRRELEVANT, ("charlie",)),
        Forbidden("d", ForbiddenReason.SUPERSEDED, ("delta",)),
    ]
    result = score(
        scenario([fact("postgres")], forbidden),
        observe(recall="postgres alpha bravo charlie"),
    )
    summary = scorer.summarize([result])
    assert (summary.recall_hits, summary.needed_hits, summary.leaks) == (1, 0, 0)
    assert summary.recall_leaks == {"wrong_audience": 1, "sensitive": 1, "superseded": 0}


def test_tokens_use_the_given_counter_per_tier():
    injection = Injection(snapshot="a b c", brief="d e", notes="f")
    result = score(scenario(), observe(injection))
    tokens = result.tokens
    assert (tokens.snapshot, tokens.brief, tokens.notes, tokens.total) == (3, 2, 1, 6)
    doubled = scorer.score_case(scenario(), observe(injection), lambda text: 2 * words(text))
    assert doubled.tokens.total == 12


@pytest.mark.parametrize(
    ("injection", "violation"),
    [
        (Injection(brief="w " * (BRIEF_TOKEN_CAP + 1)), "brief"),
        (Injection(notes="w " * 401), "notes"),
        (Injection(snapshot="w " * 701), "total"),
    ],
)
def test_cap_violation_fails_case(injection, violation):
    result = score(scenario(ceiling=10_000), observe(injection))
    assert violation in result.violations
    assert not result.passed
    assert scorer.summarize([result]).cap_violation_cases == 1


def test_exact_caps_are_not_violations():
    injection = Injection(brief="w " * 300, notes="w " * 400)
    result = score(scenario(ceiling=700), observe(injection))
    assert result.violations == ()
    assert result.passed


def test_ceiling_violation_fails_case():
    result = score(scenario(ceiling=1), observe(Injection(notes="two words")))
    assert not result.passed
    assert scorer.summarize([result]).over_ceiling_cases == 1


def test_brief_drops_count_only_needed_decisions_and_commitments():
    case = scenario(
        [
            fact("ship", kind=ItemKind.DECISION),
            fact("report", kind=ItemKind.COMMITMENT),
            fact("coffee", kind=ItemKind.PREFERENCE),
            fact("kept", kind=ItemKind.DECISION),
        ]
    )
    rewrite = BriefRewrite(1.0, PLACE, "ship report coffee kept", "kept")
    result = score(case, observe(rewrites=[rewrite]))
    assert sorted(drop.item_id for drop in result.brief_drops) == ["report", "ship"]
    assert scorer.summarize([result]).brief_drops == 2


def test_brief_drops_are_not_applicable_without_rewrites():
    assert scorer.summarize([score(scenario(), observe())]).brief_drops is None


def test_percentiles_are_nearest_rank_and_none_when_empty():
    assert scorer.percentile([], 50) is None
    assert scorer.percentile([4, 1, 3, 2], 50) == 2
    assert scorer.percentile([4, 1, 3, 2], 95) == 4
    assert scorer.percentile([7], 95) == 7
    empty = scorer.summarize([])
    assert (empty.tokens_p50, empty.tokens_p95, empty.tokens_mean) == (None, None, None)
