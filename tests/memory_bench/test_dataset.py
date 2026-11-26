from __future__ import annotations

import math
import unicodedata
from collections import Counter
from dataclasses import replace
from functools import cache

import pytest

from scripts.memory_bench.history import build_history
from scripts.memory_bench.model import (
    ADMIT_MIN_SALIENCE,
    EXPIRE_AFTER_DAYS,
    EXPIRE_BELOW_SALIENCE,
    JOKE_NOTE_COOLDOWN_DAYS,
    MAX_INJECTED_NOTES,
    MAX_WRITES_PER_TURN,
    STORE_NOTE_CAP,
    TOTAL_TOKEN_CAP,
    Category,
    ForbiddenReason,
    History,
    ItemKind,
    Kind,
    Load,
    Probe,
    Proposal,
    SalienceMode,
    Scenario,
    Source,
    Split,
    Turn,
    fold,
    mentions,
    vietnamese,
)
from scripts.memory_bench.scenarios import SCENARIOS

SEEDS = (0, 7)
VIETNAMESE_MARKS = {"̀", "́", "̃", "̉", "̣", "̂", "̆", "̛"}
CATEGORY_COUNTS = {
    Category.NEEDED: 14,
    Category.IRRELEVANT: 1,
    Category.LONG_THREAD: 1,
    Category.DUPLICATE: 1,
    Category.EXPIRY: 1,
    Category.JOKE: 1,
    Category.MUST_NOT: 1,
}
PROPOSAL_KINDS = {
    ItemKind.FACT: Kind.WORK,
    ItemKind.DECISION: Kind.WORK,
    ItemKind.COMMITMENT: Kind.WORK,
    ItemKind.PREFERENCE: Kind.PREF,
    ItemKind.JOKE: Kind.MOMENT,
}


def turns_of(scenario: Scenario) -> tuple[Turn, ...]:
    return tuple(event for event in scenario.history if isinstance(event, Turn))


def notes_of(turns: tuple[Turn, ...]) -> list[tuple[Turn, Proposal]]:
    return [(turn, proposal) for turn in turns for proposal in turn.proposals]


def written(turns: tuple[Turn, ...]) -> list[tuple[Turn, Proposal]]:
    result = []
    for turn in turns:
        admitted = [p for p in turn.proposals if p.salience >= ADMIT_MIN_SALIENCE]
        admitted.sort(key=lambda p: p.salience, reverse=True)
        result.extend((turn, p) for p in admitted[:MAX_WRITES_PER_TURN])
    return result


def alive(turn: Turn, proposal: Proposal, at: float) -> bool:
    return proposal.salience >= EXPIRE_BELOW_SALIENCE or at - turn.at <= EXPIRE_AFTER_DAYS


def visible(turn: Turn, probe: Probe) -> bool:
    if turn.owner and turn.place.source is Source.PAL_APP:
        return True
    return (turn.place.source, turn.place.channel) == (probe.place.source, probe.place.channel)


def keyed(turns: tuple[Turn, ...], key: str) -> list[tuple[Turn, Proposal]]:
    return [(turn, p) for turn, p in notes_of(turns) if p.key == key]


def is_vietnamese(text: str) -> bool:
    words = text.split()
    marked = sum(
        1
        for word in words
        if "đ" in word.casefold() or VIETNAMESE_MARKS & set(unicodedata.normalize("NFD", word))
    )
    return marked > len(words) * 0.35


def assert_distinct_markers(turns: tuple[Turn, ...], key: str, markers: tuple[str, ...], corpus: list[tuple[str, str]]) -> None:
    own = [p.text for _, p in keyed(turns, key)]
    assert own, key
    assert 1 <= len(markers) <= 3, key
    for text in own:
        assert mentions(text, markers), (key, markers, text)
    unique = [m for m in markers if not any(fold(m) in text for other, text in corpus if other != key)]
    assert unique, (key, markers, [text for other, text in corpus if other != key and mentions(text, markers)])


def folded_corpus(turns: tuple[Turn, ...]) -> list[tuple[str, str]]:
    return [(p.key, fold(p.text)) for _, p in notes_of(turns)]


def by_category(category: Category) -> list[Scenario]:
    return [s for s in SCENARIOS if s.category is category]


@cache
def history(seed: int = 0, mode: SalienceMode = SalienceMode.INFORMATIVE) -> History:
    return build_history(seed, mode)


def test_category_and_split_weighting():
    assert len({s.id for s in SCENARIOS}) == len(SCENARIOS) == 20
    assert Counter(s.category for s in SCENARIOS) == CATEGORY_COUNTS
    assert Counter(s.split for s in SCENARIOS) == {Split.DEV: 10, Split.TEST: 10}
    needed = Counter(s.split for s in by_category(Category.NEEDED))
    assert needed == {Split.DEV: 7, Split.TEST: 7}
    assert all(s.covers for s in SCENARIOS)
    for split in Split:
        reasons = {f.reason for s in SCENARIOS if s.split is split for f in s.forbidden}
        assert len(reasons) >= 4, (split, reasons)
    assert {f.reason for s in SCENARIOS for f in s.forbidden} == set(ForbiddenReason)


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s.id)
def test_events_are_ordered_and_precede_the_probe(scenario):
    times = [event.at for event in scenario.history]
    assert times == sorted(times)
    assert scenario.probe.at > times[-1]
    assert 0 <= scenario.token_ceiling <= TOTAL_TOKEN_CAP


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s.id)
def test_markers_identify_exactly_one_fact(scenario):
    turns = turns_of(scenario)
    corpus = folded_corpus(turns)
    ids = [e.id for e in scenario.expected] + [f.id for f in scenario.forbidden]
    assert len(ids) == len(set(ids))
    for entry in (*scenario.expected, *scenario.forbidden):
        assert_distinct_markers(turns, entry.id, entry.markers, corpus)
    expected_keys = {e.id for e in scenario.expected}
    for forbidden in scenario.forbidden:
        for _, p in notes_of(turns):
            if p.key in expected_keys:
                assert not mentions(p.text, forbidden.markers), (forbidden.id, p.text)


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s.id)
def test_expected_notes_are_recallable(scenario):
    turns = turns_of(scenario)
    probe = scenario.probe
    assert len(scenario.expected) <= MAX_INJECTED_NOTES
    for item in scenario.expected:
        carriers = keyed(turns, item.id)
        for turn, p in carriers:
            assert visible(turn, probe), item.id
            assert not p.sensitive, item.id
            assert p.kind is PROPOSAL_KINDS[item.kind], item.id
            assert len(turn.proposals) <= MAX_WRITES_PER_TURN, item.id
        assert any(
            p.salience >= ADMIT_MIN_SALIENCE and alive(turn, p, probe.at) and turn.at < probe.at
            for turn, p in carriers
        ), item.id


def forbidden_holds(reason: ForbiddenReason, turn: Turn, p: Proposal, scenario: Scenario) -> bool:
    probe = scenario.probe
    age = probe.at - turn.at
    if reason is ForbiddenReason.WRONG_AUDIENCE:
        return not visible(turn, probe) and not p.sensitive
    if reason is ForbiddenReason.SENSITIVE:
        return p.sensitive
    if not visible(turn, probe) or p.sensitive:
        return False
    if reason is ForbiddenReason.EXPIRED:
        return ADMIT_MIN_SALIENCE <= p.salience < EXPIRE_BELOW_SALIENCE and age > EXPIRE_AFTER_DAYS + 1
    if reason is ForbiddenReason.INCIDENT:
        return probe.incident and p.kind is Kind.MOMENT and age >= JOKE_NOTE_COOLDOWN_DAYS
    if reason is ForbiddenReason.TOO_RECENT:
        return p.kind is Kind.MOMENT and age < JOKE_NOTE_COOLDOWN_DAYS
    if reason is ForbiddenReason.SUPERSEDED:
        newer = [t.at for item in scenario.expected for t, _ in keyed(turns_of(scenario), item.id)]
        return bool(newer) and turn.at < max(newer)
    return True


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s.id)
def test_forbidden_notes_match_their_reason(scenario):
    turns = turns_of(scenario)
    for forbidden in scenario.forbidden:
        for turn, p in keyed(turns, forbidden.id):
            assert p.salience >= ADMIT_MIN_SALIENCE, forbidden.id
            assert forbidden_holds(forbidden.reason, turn, p, scenario), (forbidden.id, forbidden.reason)


@pytest.mark.parametrize("scenario", by_category(Category.NEEDED), ids=lambda s: s.id)
def test_needed_scenarios_have_competing_notes(scenario):
    expected = {e.id for e in scenario.expected}
    assert expected
    competitors = {
        p.text
        for turn, p in written(turns_of(scenario))
        if p.key not in expected
        and not p.sensitive
        and visible(turn, scenario.probe)
        and alive(turn, p, scenario.probe.at)
    }
    assert len(competitors) >= 15


def test_store_sizes_vary():
    sizes = [len(written(turns_of(s))) for s in by_category(Category.NEEDED)]
    assert min(sizes) <= 40
    assert max(sizes) >= 100


def test_irrelevant_probe_adds_nothing():
    (scenario,) = by_category(Category.IRRELEVANT)
    assert scenario.expected == ()
    assert scenario.token_ceiling == 0
    here = [
        p
        for turn, p in notes_of(turns_of(scenario))
        if turn.place.channel == scenario.probe.place.channel and p.kind is not Kind.MOMENT
    ]
    assert here == []
    assert len(written(turns_of(scenario))) >= 15


def test_long_thread_has_two_hundred_turns():
    (scenario,) = by_category(Category.LONG_THREAD)
    places = Counter(turn.place for turn in turns_of(scenario))
    place, count = places.most_common(1)[0]
    assert place.thread and count >= 200
    assert scenario.probe.place == place
    thread = [t for t in turns_of(scenario) if t.place == place]
    for item in scenario.expected:
        first = keyed(turns_of(scenario), item.id)[0][0]
        assert thread.index(first) < 60


def test_duplicate_fact_is_said_five_times():
    (scenario,) = by_category(Category.DUPLICATE)
    counts = [len(keyed(turns_of(scenario), item.id)) for item in scenario.expected]
    assert max(counts) >= 5


def test_expiry_and_joke_scenarios_carry_their_cases():
    (expiry,) = by_category(Category.EXPIRY)
    assert ForbiddenReason.EXPIRED in {f.reason for f in expiry.forbidden}
    (joke,) = by_category(Category.JOKE)
    (item,) = [e for e in joke.expected if e.kind is ItemKind.JOKE]
    turn, _ = keyed(turns_of(joke), item.id)[0]
    assert joke.probe.at - turn.at >= 21
    assert not joke.probe.incident
    (must_not,) = by_category(Category.MUST_NOT)
    assert not [e for e in must_not.expected if e.kind is ItemKind.JOKE]
    blocked = {
        f.reason
        for f in must_not.forbidden
        if keyed(turns_of(must_not), f.id)[0][1].kind is Kind.MOMENT
    }
    assert blocked & {ForbiddenReason.SENSITIVE, ForbiddenReason.WRONG_AUDIENCE}


def test_near_cap_scenario_overflows_the_store():
    scenario = max(SCENARIOS, key=lambda s: len(written(turns_of(s))))
    live = [
        (turn, p) for turn, p in written(turns_of(scenario)) if alive(turn, p, scenario.probe.at)
    ]
    assert len({p.text for _, p in live}) >= STORE_NOTE_CAP + 50
    keys = [p.key for _, p in live]
    for item in scenario.expected:
        assert keys.index(item.id) < len(keys) // 5


def test_owner_words_from_the_app_are_needed_in_slack():
    assert any(
        s.probe.place.source is Source.SLACK
        and any(
            turn.owner and turn.place.source is Source.PAL_APP
            for item in s.expected
            for turn, _ in keyed(turns_of(s), item.id)
        )
        for s in SCENARIOS
    )


def test_recall_across_threads_disagreement_and_topic_noise():
    needed = by_category(Category.NEEDED)
    crossed = [
        s
        for s in needed
        for item in s.expected
        for turn, _ in keyed(turns_of(s), item.id)[:1]
        if turn.place.thread
        and turn.place.thread != s.probe.place.thread
        and int(s.probe.at) > int(turn.at)
    ]
    assert crossed
    disagreements = []
    changed_same, changed_different, shared = [], [], []
    for s in needed:
        carriers = [keyed(turns_of(s), item.id)[0] for item in s.expected]
        if len({t.speaker for t, _ in carriers}) >= 2 and len({t.place for t, _ in carriers}) == 1:
            disagreements.append(s.id)
        if len(carriers) >= 2 and len({p.topic for _, p in carriers}) < len(carriers):
            shared.append(s.id)
        for forbidden in s.forbidden:
            if forbidden.reason is not ForbiddenReason.SUPERSEDED:
                continue
            old_topic = keyed(turns_of(s), forbidden.id)[0][1].topic
            same = old_topic in {p.topic for _, p in carriers}
            (changed_same if same else changed_different).append(s.id)
    assert disagreements and changed_same and changed_different and shared


def test_texts_are_normalised_mixed_language_and_never_copied():
    notes: set[str] = set()
    probes: list[str] = []
    said: list[str] = []
    for s in SCENARIOS:
        own_notes = [fold(p.text) for _, p in notes_of(turns_of(s))]
        query = fold(s.probe.text)
        assert not any(query in note or note in query for note in own_notes), s.id
        notes.update(p.text for _, p in notes_of(turns_of(s)))
        probes.append(s.probe.text)
        said.extend(t.text for t in turns_of(s))
    run = history()
    notes.update(p.text for _, p in notes_of(run.turns))
    probes.extend(q.probe.text for q in run.questions)
    said.extend(t.text for t in run.turns)
    for texts, low, high in ((notes, 0.35, 0.65), (probes, 0.35, 0.65), (said, 0.3, 0.7)):
        assert all(unicodedata.is_normalized("NFC", text) for text in texts)
        share = sum(map(is_vietnamese, texts)) / len(texts)
        assert low <= share <= high, share


def needed_view(run: History) -> set[tuple]:
    return {(q.item, q.probe, int(q.said_at), q.forbidden) for q in run.questions}


def needed_keys(run: History) -> set[str]:
    return {q.item.id for q in run.questions} | {f.id for q in run.questions for f in q.forbidden}


def test_history_has_the_fixed_needed_set_in_every_age_bucket():
    run = history()
    assert run.last_day == 30
    assert len({q.item.id for q in run.questions}) >= 66
    ages = [run.last_day - math.floor(said_at) for said_at in {q.item.id: q.said_at for q in run.questions}.values()]
    for low, high in ((0, 7), (8, 14), (15, 30)):
        assert sum(low <= age <= high for age in ages) >= 20
    assert {q.item.kind for q in run.questions} >= {
        ItemKind.FACT,
        ItemKind.DECISION,
        ItemKind.COMMITMENT,
        ItemKind.PREFERENCE,
    }
    for seed in SEEDS[1:]:
        assert needed_view(history(seed)) == needed_view(run)
        first = {(p.key, p.text, p.topic) for _, p in notes_of(run.turns) if p.key in needed_keys(run)}
        other = {
            (p.key, p.text, p.topic)
            for _, p in notes_of(history(seed).turns)
            if p.key in needed_keys(run)
        }
        assert first == other


def test_history_is_deterministic_and_seed_sensitive():
    for mode in SalienceMode:
        assert build_history(3, mode) == build_history(3, mode)
    first, second = history(SEEDS[0]), history(SEEDS[1])
    assert {p.text for _, p in notes_of(first.turns)} != {p.text for _, p in notes_of(second.turns)}


@pytest.mark.parametrize("seed", SEEDS)
def test_history_volume_places_and_order(seed):
    run = history(seed)
    times = [t.at for t in run.turns]
    assert times == sorted(times)
    assert 0 <= times[0] and times[-1] < run.last_day + 1
    per_day_turns = Counter(int(t.at) for t in run.turns)
    per_day_notes = Counter(int(t.at) for t, _ in notes_of(run.turns))
    assert set(per_day_turns) == set(range(run.last_day + 1))
    assert all(32 <= per_day_turns[day] <= 55 for day in per_day_turns)
    assert all(22 <= per_day_notes[day] <= 40 for day in per_day_turns)
    assert len(notes_of(run.turns)) >= 850
    first_ask = run.questions[0].probe.at
    live = {p.text for t, p in written(run.turns) if alive(t, p, first_ask)}
    assert len(live) > STORE_NOTE_CAP
    channels = {(t.place.source, t.place.channel) for t in run.turns}
    assert sum(source is Source.PAL_APP for source, _ in channels) == 1
    assert 4 <= sum(source is Source.SLACK for source, _ in channels) <= 6
    assert all(t.owner for t in run.turns if t.place.source is Source.PAL_APP)
    for question in run.questions:
        assert times[-1] < question.probe.at < run.last_day + 2


@pytest.mark.parametrize("seed", SEEDS)
def test_history_questions_are_answerable(seed):
    run = history(seed)
    pal_asked_in_slack = owners = others = restated = 0
    for question in run.questions:
        carriers = keyed(run.turns, question.item.id)
        assert math.isclose(question.said_at, carriers[-1][0].at), question.item.id
        restated += len(carriers) > 1
        for turn, p in carriers:
            assert visible(turn, question.probe), question.item.id
            assert not p.sensitive and p.salience >= ADMIT_MIN_SALIENCE
            assert p.kind is PROPOSAL_KINDS[question.item.kind], question.item.id
            assert len(turn.proposals) <= MAX_WRITES_PER_TURN
        turn = carriers[0][0]
        owners += turn.owner
        others += not turn.owner
        pal_asked_in_slack += (
            turn.place.source is Source.PAL_APP and question.probe.place.source is Source.SLACK
        )
    assert owners >= 20 and others >= 20 and pal_asked_in_slack >= 8 and restated >= 6


@pytest.mark.parametrize("seed", SEEDS)
def test_history_markers_never_collide(seed):
    run = history(seed)
    corpus = folded_corpus(run.turns)
    for question in run.questions:
        assert_distinct_markers(run.turns, question.item.id, question.item.markers, corpus)
        for forbidden in question.forbidden:
            assert_distinct_markers(run.turns, forbidden.id, forbidden.markers, corpus)
        query = fold(question.probe.text)
        assert not any(query in text or text in query for _, text in corpus)
        for forbidden in question.forbidden:
            assert not mentions(question.probe.text, forbidden.markers)
            for _, p in keyed(run.turns, question.item.id):
                assert not mentions(p.text, forbidden.markers)


def test_history_changed_decisions():
    run = history()
    same = different = 0
    for question in run.questions:
        for forbidden in question.forbidden:
            assert forbidden.reason is ForbiddenReason.SUPERSEDED
            old_turn, old = keyed(run.turns, forbidden.id)[0]
            new_turn, new = keyed(run.turns, question.item.id)[0]
            assert old_turn.at < new_turn.at
            assert visible(old_turn, question.probe)
            same += old.topic == new.topic
            different += old.topic != new.topic
    assert same >= 3 and different >= 3


@pytest.mark.parametrize("seed", SEEDS)
def test_salience_modes(seed):
    informative = history(seed, SalienceMode.INFORMATIVE)
    noisy = history(seed, SalienceMode.NOISY)
    flat = history(seed, SalienceMode.FLAT)
    keys = needed_keys(informative)
    for run, needed_range, filler_range in (
        (informative, (0.7, 0.95), (0.1, 0.55)),
        (noisy, (0.45, 0.9), (0.15, 0.8)),
        (flat, (0.6, 0.6), (0.6, 0.6)),
    ):
        for _, p in notes_of(run.turns):
            low, high = needed_range if p.key in keys else filler_range
            assert low <= p.salience <= high, (p.key, p.salience)
    texts = [[p.text for _, p in notes_of(run.turns)] for run in (informative, noisy, flat)]
    assert texts[0] == texts[1] == texts[2]


@pytest.mark.parametrize("seed", SEEDS)
def test_at_cap_history_is_denser_and_longer_with_the_same_needed_set(seed):
    typical = history(seed)
    capped = build_history(seed, SalienceMode.INFORMATIVE, Load.AT_CAP)
    assert capped == build_history(seed, SalienceMode.INFORMATIVE, Load.AT_CAP)
    assert [q.item for q in capped.questions] == [q.item for q in typical.questions]
    typical_words = [len(p.text.split()) for _, p in notes_of(typical.turns)]
    capped_words = [len(p.text.split()) for _, p in notes_of(capped.turns)]
    assert len(capped_words) >= 1.8 * len(typical_words)
    assert sum(capped_words) / len(capped_words) >= 1.8 * sum(typical_words) / len(typical_words)


@pytest.mark.parametrize("seed", SEEDS)
def test_at_cap_markers_never_match_another_fact(seed):
    capped = build_history(seed, SalienceMode.INFORMATIVE, Load.AT_CAP)
    corpus = folded_corpus(capped.turns)
    for question in capped.questions:
        for entry in (question.item, *question.forbidden):
            assert_distinct_markers(capped.turns, entry.id, entry.markers, corpus)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Hạnh chốt ngày 4/3 rằng phí trễ hạn là một phần trăm mỗi tháng.", True),
        ("On 4/3, Hạnh and Quân agreed the Mây Tre catalogue ships to the printer on Friday.", False),
    ],
)
def test_vietnamese_is_told_apart_from_english_with_vietnamese_names(text, expected):
    assert vietnamese(text) is expected


@pytest.mark.parametrize("seed", SEEDS)
def test_question_age_counts_from_the_last_time_the_fact_was_said(seed):
    run = history(seed)
    for question in run.questions:
        assert question.said_at == max(turn.at for turn, _ in keyed(run.turns, question.item.id))


@pytest.mark.parametrize("load", list(Load))
def test_history_filler_never_reuses_a_needed_topic(load):
    run = build_history(0, SalienceMode.INFORMATIVE, load)
    needed = {p.topic for _, p in notes_of(run.turns) if not p.key.startswith("f-")}
    filler = {p.topic for _, p in notes_of(run.turns) if p.key.startswith("f-")}
    assert not needed & filler


def test_near_cap_scenario_really_pushes_the_store_past_its_cap():
    (case,) = [s for s in SCENARIOS if "past its cap" in s.covers]
    slots = {
        ("anywhere" if turn.owner and turn.place.source is Source.PAL_APP else turn.place.channel, p.topic)
        for turn, p in notes_of(turns_of(case))
        if p.salience >= ADMIT_MIN_SALIENCE
    }
    assert len(slots) >= STORE_NOTE_CAP + 40


@pytest.mark.parametrize("seed", SEEDS)
def test_every_needed_item_is_asked_once_in_each_language_under_the_same_conditions(seed):
    run = history(seed)
    asked: dict[str, list] = {}
    for question in run.questions:
        asked.setdefault(question.item.id, []).append(question)
    for item_id, pair in asked.items():
        assert len(pair) == 2, item_id
        assert {vietnamese(q.probe.text) for q in pair} == {True, False}, [q.probe.text for q in pair]
        first, second = pair
        assert (first.item, first.said_at, first.forbidden) == (second.item, second.said_at, second.forbidden)
        assert replace(first.probe, at=0.0, text="") == replace(second.probe, at=0.0, text="")
    assert len({q.probe.at for q in run.questions}) == len(run.questions)

