from __future__ import annotations

import sqlite3
import time
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType

from gateway import commitments as ledger
from gateway.commitments import Actor, State
from gateway.proactive_scorecard.mining import PersistenceSource, SessionSource, Stats, count_reach, tally
from gateway.proactive_scorecard.rubric import RUBRIC_VERSION

SCHEMA = "proactive-scorecard/1"
TOKEN_BASIS = "estimate: characters the owner typed divided by four; tokenizer counts are not recorded"
NO_STORE = "n/a: this profile has no state.db"


class Better(StrEnum):
    LOWER = "lower"
    HIGHER = "higher"
    ZERO = "zero"


@dataclass(frozen=True, slots=True)
class Window:
    since: float
    until: float


@dataclass(frozen=True, slots=True)
class Spec:
    key: str
    label: str
    numerator: str
    denominator: str
    better: Better
    scale: int | None = 1
    basis: str = "rules"


SPECS: tuple[Spec, ...] = (
    Spec("avoidable_ask_rate", "avoidable ask rate", "avoidable question turns", "question turns", Better.LOWER),
    Spec("unsure_asks", "unsure asks", "question turns no rule labels", "question turns", Better.LOWER),
    Spec("missed_needed_asks", "missed needed asks", "needed asks never made", "needed asks", Better.LOWER),
    Spec("handbacks", "handbacks per 100", "handback turns", "assistant turns", Better.LOWER, 100),
    Spec("nudges_per_100_owner_turns", "nudges per 100", "owner correction messages", "owner turns",
         Better.LOWER, 100),
    Spec("gate_violations", "gate violations", "overreach complaints", "owner turns", Better.ZERO, None),
    Spec("owner_tokens_per_task", "owner tokens per task", "owner tokens", "tasks", Better.LOWER,
         basis=TOKEN_BASIS),
    Spec("idle_reach_acted_share", "idle reach acted", "offers acted on", "offers acted on or dismissed",
         Better.HIGHER),
    Spec("with_options_share", "asks with options", "asks with options", "asks", Better.HIGHER),
    Spec("recommended_first_share", "recommended first", "asks with the recommended option first",
         "asks with options", Better.HIGHER),
    Spec("bare_yes_no_share", "bare yes/no asks", "yes/no-only asks", "asks with options", Better.LOWER),
    Spec("no_options_no_default_share", "bare open asks", "asks with no options and no default", "asks",
         Better.LOWER),
    Spec("asks_per_task", "asks per task", "asks", "tasks", Better.LOWER),
    Spec("kept_rate", "kept rate", "promises done", "done + bot-abandoned + overdue promises", Better.HIGHER),
    Spec("follow_through", "follow-through", "promises closed", "promises made", Better.HIGHER),
    Spec("owner_chases", "owner chases per 100", "chase messages", "owner turns", Better.LOWER, 100),
    Spec("unrecorded_promises", "unrecorded promises", "promise turns with no commitment event", "promise turns",
         Better.LOWER),
)
_SPEC: Mapping[str, Spec] = MappingProxyType({spec.key: spec for spec in SPECS})
_LEDGER_KEYS = ("kept_rate", "follow_through")
_REACH_KEYS = ("idle_reach_acted_share",)
_ALWAYS_NA = MappingProxyType({
    "missed_needed_asks": "n/a: replay only; a live transcript has no counterfactual "
                          "(python -m evals.proactive_eval replay)",
})


@dataclass(frozen=True, slots=True)
class Metric:
    spec: Spec
    value: float | None
    numerator: int | None
    denominator: int | None
    na: str | None

    @property
    def key(self) -> str:
        return self.spec.key

    @property
    def label(self) -> str:
        return self.spec.label

    @property
    def basis(self) -> str:
        return self.spec.basis

    @property
    def hard_fail(self) -> bool:
        return self.spec.better is Better.ZERO and bool(self.numerator)


@dataclass(frozen=True, slots=True)
class Scorecard:
    window: Window
    metrics: Mapping[str, Metric]

    @property
    def hard_fail(self) -> bool:
        return any(metric.hard_fail for metric in self.metrics.values())


Fraction = tuple[int, int, str]


def _metric(key: str, fraction: Fraction | str) -> Metric:
    spec = _SPEC[key]
    if isinstance(fraction, str):
        return Metric(spec, None, None, None, fraction)
    numerator, denominator, why = fraction
    if not denominator:
        return Metric(spec, None, numerator, denominator, f"n/a: {why}")
    value = numerator if spec.scale is None else round(spec.scale * numerator / denominator, 4)
    return Metric(spec, value, numerator, denominator, None)


def _transcript_fractions(stats: Stats) -> dict[str, Fraction]:
    no_questions, no_owner, no_tasks = "no question turns", "no owner turns", "no conversations"
    no_asks, no_options = "no asks", "no asks with options"
    return {
        "avoidable_ask_rate": (stats.avoidable, stats.question_turns, no_questions),
        "unsure_asks": (stats.unclassified, stats.question_turns, no_questions),
        "handbacks": (stats.handbacks, stats.assistant_turns, "no assistant turns"),
        "nudges_per_100_owner_turns": (sum(stats.corrections.values()), stats.owner_turns, no_owner),
        "gate_violations": (stats.corrections["overreach_complaint"], stats.owner_turns, no_owner),
        "owner_tokens_per_task": (stats.owner_tokens, stats.sessions, no_tasks),
        "with_options_share": (stats.asks_with_options, stats.asks, no_asks),
        "recommended_first_share": (stats.asks_recommended_first, stats.asks_with_options, no_options),
        "bare_yes_no_share": (stats.asks_bare_yes_no, stats.asks_with_options, no_options),
        "no_options_no_default_share": (stats.asks_no_options_no_default, stats.asks, no_asks),
        "asks_per_task": (stats.asks, stats.sessions, no_tasks),
        "owner_chases": (stats.owner_chases, stats.owner_turns, no_owner),
        "unrecorded_promises": (stats.unrecorded_promises, stats.promise_turns, "no promise-like turns"),
    }


def _read_only(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _has_table(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (name,)).fetchone() is not None


def _inside(window: Window, moment: float | None) -> bool:
    return moment is not None and window.since <= moment < window.until


def _ledger_fractions(conn: sqlite3.Connection, window: Window, as_of: float) -> dict[str, Fraction | str]:
    if not _has_table(conn, "commitments"):
        return dict.fromkeys(_LEDGER_KEYS, "n/a: no promise recorded yet")
    made = done = dropped = overdue = closed_made = 0
    for item in ledger.outcomes(conn, as_of=as_of):
        if _inside(window, item.created_at):
            made += 1
            closed_made += item.closed is not None
        if _inside(window, item.closed_at):
            done += item.closed is State.DONE
            dropped += item.closed is State.ABANDONED and item.closed_by is Actor.BOT
        overdue += item.closed is None and _inside(window, item.due_at) and item.due_at < as_of
    return {"kept_rate": (done, done + dropped + overdue, "no promise was done, dropped by the bot or overdue"),
            "follow_through": (closed_made, made, "no promise made")}


def _reach_fractions(conn: sqlite3.Connection, window: Window) -> dict[str, Fraction | str]:
    if not _has_table(conn, "reach_offers"):
        return dict.fromkeys(_REACH_KEYS, "n/a: no proactive offer recorded yet")
    rows = [dict(row) for row in conn.execute(
        "SELECT domain, status, outcome, created_at FROM reach_offers WHERE created_at >= ? AND created_at < ?",
        (window.since, window.until))]
    cells = [cell for domains in count_reach(rows)["weeks"].values() for cell in domains.values()]
    acted = sum(cell.get("outcome_acted", 0) for cell in cells)
    dismissed = sum(cell.get("outcome_dismissed", 0) for cell in cells)
    return {"idle_reach_acted_share": (acted, acted + dismissed, "no offer was acted on or dismissed")}


def compute(window: Window, home, *, now: float | None = None, sessions: SessionSource | None = None) -> Scorecard:
    home = Path(home)
    store = home / "state.db"
    fractions: dict[str, Fraction | str] = dict(_ALWAYS_NA)
    if not store.is_file():
        fractions.update({spec.key: NO_STORE for spec in SPECS if spec.key not in fractions})
    else:
        as_of = min(window.until, time.time() if now is None else now)
        source = sessions or PersistenceSource(home)
        fractions.update(_transcript_fractions(tally(source, since=window.since, until=window.until)))
        conn = _read_only(store)
        try:
            fractions.update(_ledger_fractions(conn, window, as_of))
            fractions.update(_reach_fractions(conn, window))
        finally:
            conn.close()
    return Scorecard(window, MappingProxyType({spec.key: _metric(spec.key, fractions[spec.key]) for spec in SPECS}))


@dataclass(frozen=True, slots=True)
class Movement:
    key: str
    label: str
    before: Metric
    after: Metric

    @property
    def change(self) -> float | None:
        if self.before.value is None or self.after.value is None:
            return None
        return round(self.after.value - self.before.value, 4)

    @property
    def relative(self) -> float:
        change = self.change
        if not change:
            return 0.0
        return abs(change) / max(abs(self.before.value), abs(self.after.value))


def compare(before: Scorecard, after: Scorecard) -> tuple[Movement, ...]:
    return tuple(Movement(spec.key, spec.label, before.metrics[spec.key], after.metrics[spec.key]) for spec in SPECS)


def moved_most(moves: Iterable[Movement], count: int = 3) -> list[Movement]:
    ranked = sorted((move for move in moves if move.relative), key=lambda move: -move.relative)
    return ranked[:count]


def format_value(metric: Metric) -> str:
    if metric.value is None:
        return "n/a"
    return str(int(metric.value)) if metric.spec.scale is None else f"{metric.value:.2f}"


def _metric_json(metric: Metric) -> dict:
    return {"label": metric.label, "value": metric.value, "numerator": metric.numerator,
            "denominator": metric.denominator, "na": metric.na, "numerator_label": metric.spec.numerator,
            "denominator_label": metric.spec.denominator, "better": metric.spec.better.value,
            "basis": metric.basis, "hard_fail": metric.hard_fail}


def to_json(card: Scorecard) -> dict:
    return {"schema": SCHEMA, "rubric_version": RUBRIC_VERSION,
            "window": {"since": card.window.since, "until": card.window.until}, "hard_fail": card.hard_fail,
            "metrics": {key: _metric_json(metric) for key, metric in card.metrics.items()}}


def comparison_json(before: Scorecard, after: Scorecard) -> dict:
    return {"schema": SCHEMA, "before": to_json(before), "after": to_json(after),
            "changes": {move.key: move.change for move in compare(before, after)}}


def _stamp(moment: float) -> str:
    from hermes_time import get_timezone
    return datetime.fromtimestamp(moment, tz=get_timezone()).strftime("%Y-%m-%d %H:%M")


def _fraction(metric: Metric) -> str:
    if metric.numerator is None:
        return metric.na or ""
    text = f"{metric.numerator} / {metric.denominator} {metric.spec.denominator}"
    return f"{text}  ({metric.na})" if metric.na else text


def _hard_fail_lines(card: Scorecard) -> list[str]:
    return [f"HARD FAIL: {metric.label} {metric.numerator} (must be 0)"
            for metric in card.metrics.values() if metric.hard_fail]


def render_text(card: Scorecard, *, label: str | None = None) -> str:
    title = f"Scorecard {_stamp(card.window.since)} to {_stamp(card.window.until)}"
    lines = [f"{title}  [{label}]" if label else title, f"{'METRIC':<24}  {'VALUE':>7}  NUMERATOR / DENOMINATOR"]
    for metric in card.metrics.values():
        lines.append(f"{metric.label:<24}  {format_value(metric):>7}  {_fraction(metric)}")
    lines.append(f"owner tokens: {TOKEN_BASIS}")
    return "\n".join(lines + _hard_fail_lines(card))


def _signed(change: float | None) -> str:
    return "n/a" if change is None else f"{change:+.2f}"


def render_comparison(moves: Iterable[Movement]) -> str:
    lines = [f"{'METRIC':<24}  {'BEFORE':>7}  {'AFTER':>7}  {'CHANGE':>7}"]
    lines += [f"{move.label:<24}  {format_value(move.before):>7}  {format_value(move.after):>7}  "
              f"{_signed(move.change):>7}" for move in moves]
    return "\n".join(lines)
