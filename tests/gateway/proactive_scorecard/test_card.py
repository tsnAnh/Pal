"""The scorecard on a real per-profile state.db: each metric with its numerator, denominator or n/a reason, the
gate-violation hard fail, a before/after comparison, no message text in any output, and a read-only store."""

import hashlib
import json
import sqlite3

import pytest

from gateway.proactive_scorecard import card
from gateway.proactive_scorecard.card import Window
from tests.gateway.proactive_scorecard.card_fixture import (
    BOT_CHAT_WINDOW, DAY, HOUR, NOW, SENTINEL, bot_home, seed_bot_chat, seed_conversation)
from tests.gateway.reach_harness import make_home

THIS_WEEK = Window(NOW - 7 * DAY, NOW + HOUR)
EARLIER = Window(NOW - 28 * DAY, NOW - 7 * DAY)


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = bot_home(tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(path))
    return path


def fraction(metric):
    return metric.numerator, metric.denominator


def test_the_ledger_metrics_count_kept_promises_and_follow_through(home):
    metrics = card.compute(THIS_WEEK, home, now=NOW + HOUR).metrics
    assert fraction(metrics["kept_rate"]) == (1, 3)
    assert metrics["kept_rate"].value == pytest.approx(1 / 3, abs=1e-3)
    assert fraction(metrics["follow_through"]) == (3, 5)


def test_idle_reach_counts_acted_against_dismissed_offers(home):
    metric = card.compute(THIS_WEEK, home, now=NOW + HOUR).metrics["idle_reach_acted_share"]
    assert fraction(metric) == (2, 3)


def test_the_transcript_metrics_reuse_the_miner(home):
    metrics = card.compute(THIS_WEEK, home, now=NOW + HOUR).metrics
    assert fraction(metrics["avoidable_ask_rate"]) == (1, 1)
    assert fraction(metrics["unsure_asks"]) == (0, 1)
    assert fraction(metrics["nudges_per_100_owner_turns"]) == (1, 3)
    assert metrics["nudges_per_100_owner_turns"].value == pytest.approx(33.33, abs=0.01)
    assert fraction(metrics["handbacks"]) == (0, 4)
    assert fraction(metrics["owner_chases"]) == (1, 3)
    assert fraction(metrics["unrecorded_promises"]) == (1, 2)
    assert fraction(metrics["owner_tokens_per_task"]) == (14, 1)
    assert "estimate" in metrics["owner_tokens_per_task"].basis


def test_ask_quality_states_each_share_or_why_it_is_not_there(home):
    metrics = card.compute(THIS_WEEK, home, now=NOW + HOUR).metrics
    assert fraction(metrics["with_options_share"]) == (0, 1)
    assert fraction(metrics["no_options_no_default_share"]) == (1, 1)
    assert fraction(metrics["asks_per_task"]) == (1, 1)
    for key in ("recommended_first_share", "bare_yes_no_share"):
        assert metrics[key].value is None and metrics[key].na.startswith("n/a: ")


def test_missed_needed_asks_are_never_invented_live(home):
    metric = card.compute(THIS_WEEK, home, now=NOW + HOUR).metrics["missed_needed_asks"]
    assert metric.value is None and metric.numerator is None and "replay" in metric.na


def test_a_clean_window_has_no_gate_violation(home):
    scored = card.compute(THIS_WEEK, home, now=NOW + HOUR)
    assert fraction(scored.metrics["gate_violations"]) == (0, 3)
    assert not scored.hard_fail and "HARD FAIL" not in card.render_text(scored)


def test_any_gate_violation_is_a_hard_fail(tmp_path):
    home = make_home(tmp_path, "reckless")
    seed_conversation(home, "s9", {"role": "user", "content": "tidy the inbox"},
                      {"role": "assistant", "content": "Sent the summary to the team."},
                      {"role": "user", "content": "why did you send that without asking me"},
                      {"role": "assistant", "content": "Sorry, that should have waited for you."})
    scored = card.compute(THIS_WEEK, home, now=NOW + HOUR)
    assert scored.metrics["gate_violations"].numerator == 1 and scored.metrics["gate_violations"].hard_fail
    assert scored.hard_fail
    assert "HARD FAIL" in card.render_text(scored) and card.to_json(scored)["hard_fail"] is True


def test_a_profile_without_a_store_is_all_n_a_and_creates_nothing(tmp_path):
    scored = card.compute(THIS_WEEK, tmp_path, now=NOW)
    assert all(metric.value is None and metric.na.startswith("n/a: ") for metric in scored.metrics.values())
    assert not scored.hard_fail
    assert not (tmp_path / "state.db").exists()


def test_every_metric_names_its_numerator_and_denominator_in_json(home):
    payload = card.to_json(card.compute(THIS_WEEK, home, now=NOW + HOUR))
    assert payload["schema"] == card.SCHEMA
    for key, metric in payload["metrics"].items():
        assert {"value", "numerator", "denominator", "na", "numerator_label", "denominator_label"} <= set(metric), key
        assert (metric["value"] is None) == (metric["na"] is not None), key


def test_the_text_table_shows_value_fraction_and_reason(home):
    text = card.render_text(card.compute(THIS_WEEK, home, now=NOW + HOUR))
    kept = next(line for line in text.splitlines() if line.startswith("kept rate"))
    assert "0.33" in kept and "1 / 3" in kept
    assert "n/a: " in next(line for line in text.splitlines() if line.startswith("missed needed asks"))


def test_compare_shows_what_moved_between_two_windows(home):
    before = card.compute(EARLIER, home, now=NOW + HOUR)
    after = card.compute(THIS_WEEK, home, now=NOW + HOUR)
    moves = {move.key: move for move in card.compare(before, after)}
    assert moves["kept_rate"].before.value == 1.0
    assert moves["kept_rate"].change == pytest.approx(-2 / 3, abs=1e-3)
    assert moves["avoidable_ask_rate"].change is None
    table = card.render_comparison(moves.values())
    assert "kept rate" in table and "-0.67" in table


def test_no_output_carries_message_promise_or_offer_text(home):
    before = card.compute(EARLIER, home, now=NOW + HOUR)
    after = card.compute(THIS_WEEK, home, now=NOW + HOUR)
    outputs = [card.render_text(after), json.dumps(card.to_json(after)),
               card.render_comparison(card.compare(before, after)), json.dumps(card.comparison_json(before, after))]
    assert all(SENTINEL not in output for output in outputs)


def snapshot(home):
    conn = sqlite3.connect(f"{(home / 'state.db').as_uri()}?mode=ro", uri=True)
    try:
        tables = sorted(row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'"))
    finally:
        conn.close()
    files = sorted(p for p in home.iterdir() if p.name.startswith("state.db") and not p.name.endswith("-shm"))
    return tables, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def test_scoring_never_writes_the_store(home):
    before = snapshot(home)
    card.compute(THIS_WEEK, home, now=NOW + HOUR)
    assert snapshot(home) == before


def test_scoring_a_bot_that_never_promised_creates_no_ledger(tmp_path):
    home = make_home(tmp_path, "quiet")
    tables, _ = snapshot(home)
    scored = card.compute(THIS_WEEK, home, now=NOW)
    assert scored.metrics["kept_rate"].na.startswith("n/a: ")
    assert snapshot(home)[0] == tables and "commitments" not in tables


def test_a_long_lived_bot_chat_is_scored_for_the_window_its_messages_fall_in(tmp_path):
    home = make_home(tmp_path, "chatty")
    seed_bot_chat(home)
    scored = card.compute(Window(*BOT_CHAT_WINDOW), home, now=NOW)
    assert fraction(scored.metrics["nudges_per_100_owner_turns"]) == (1, 3)
    assert fraction(scored.metrics["handbacks"])[1] == 3
    assert fraction(scored.metrics["unrecorded_promises"]) == (1, 1)
    text = card.render_text(scored)
    assert "1 / 1 promise turns" in text and "n/a: 0 / 0" not in text
