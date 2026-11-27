from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from collections import Counter
from collections.abc import Callable, Iterable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import Enum
from itertools import pairwise
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from evals.intent.heuristics import (
    STEM_CAP, AskKey, Change, Signal, change_of, correction_shapes, failed, listed_options, own_words,
    question_signals, question_stem, redacted_shape, restates, says_again,
)
from evals.intent.transcripts import Author, Call, Turn, read_transcripts
from gateway.host_rendezvous import served_profiles
from gateway.proactive_scorecard.patterns import correction_classes, is_bare_yes_no, states_recommendation
from hermes_cli.profiles import get_profile_dir, profile_exists
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tools.clarify_tool import MAX_CHOICES, strip_recommended

SCHEMA = "intent-baseline/1"
DAY = 86400.0
SHAPE_LIMIT = 5
TRIGGER_CHANGES = (Change.CODE_EDIT, Change.OUTBOUND_SEND, Change.SPEND, Change.CONFIG)


class Delivery(Enum):
    ASKED = "asked"
    REJECTED = "rejected"
    NOT_SHOWN = "not_shown"


@dataclass(frozen=True, slots=True)
class Question:
    text: str
    choices: tuple[str, ...]
    recommend: bool
    multi_select: bool
    has_send: bool

    @property
    def recommended_first(self) -> bool:
        return bool(self.choices) and self.recommend and (
            len(self.choices) >= 2 or states_recommendation(self.choices[0]))

    @property
    def real_options(self) -> bool:
        return len(self.choices) >= 2 and not is_bare_yes_no(self.choices)

    @property
    def other_row(self) -> bool:
        return bool(self.choices) and not self.multi_select


@dataclass(frozen=True, slots=True)
class Form:
    position: tuple[int, int]
    delivery: Delivery
    questions: tuple[Question, ...]


@dataclass(frozen=True, slots=True)
class Reading:
    author: Author
    text: str
    at: float
    final_text: str
    signals: frozenset[Signal]
    forms: tuple[Form, ...]
    changes: tuple[tuple[tuple[int, int], Change], ...]
    question_steps: frozenset[int]
    restated_steps: frozenset[int]

    @property
    def asked_forms(self) -> tuple[Form, ...]:
        return tuple(form for form in self.forms if form.delivery is Delivery.ASKED)

    @property
    def trigger_changes(self) -> tuple[tuple[tuple[int, int], Change], ...]:
        return tuple(item for item in self.changes if item[1] in TRIGGER_CHANGES)


def _listed(value: object) -> list:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return []
    return value if isinstance(value, list) else []


def _questions(arguments: dict) -> tuple[Question, ...]:
    found = []
    for item in _listed(arguments.get("questions")):
        if not isinstance(item, dict) or not str(item.get("question") or "").strip():
            continue
        offered = item.get("choices") if isinstance(item.get("choices"), list) else []
        choices = tuple(strip_recommended(c) for c in offered if str(c).strip())[:MAX_CHOICES]
        found.append(Question(str(item["question"]).strip(), choices, item.get("recommend") is not False,
                              bool(item.get("multi_select")) and bool(choices), bool(item.get("send"))))
    return tuple(found)


def _delivery(call: Call, results: dict[str, str]) -> Delivery:
    try:
        payload = json.loads(results.get(call.call_id) or "null")
    except ValueError:
        return Delivery.ASKED
    if not isinstance(payload, dict):
        return Delivery.ASKED
    if "error" in payload:
        return Delivery.REJECTED
    return Delivery.NOT_SHOWN if payload.get("outcome") in ("not_asked", "undelivered") else Delivery.ASKED


def _final_text(turn: Turn) -> str:
    spoken = next((step for step in reversed(turn.steps) if step.text.strip()), None)
    if spoken is None or any(call.name == "clarify" for call in spoken.calls):
        return ""
    return own_words(spoken.text)


def _read(turn: Turn) -> Reading:
    forms, changes = [], []
    for step_index, step in enumerate(turn.steps):
        for call_index, call in enumerate(step.calls):
            position = (step_index, call_index)
            if call.name == "clarify":
                forms.append(Form(position, _delivery(call, turn.results), _questions(call.arguments)))
            elif ((change := change_of(call.name, call.arguments))
                  and not failed(turn.results.get(call.call_id, ""))):
                changes.append((position, change))
    final = _final_text(turn)
    spoken = [own_words(step.text) for step in turn.steps]
    return Reading(
        turn.author, turn.text, turn.at, final, question_signals(final), tuple(forms), tuple(changes),
        frozenset(index for index, text in enumerate(spoken) if question_signals(text)),
        frozenset(index for index, text in enumerate(spoken) if restates(text)))


def fraction(count: int, n: int) -> dict:
    return {"count": count, "n": n, "share": round(count / n, 4) if n else None}


def _fractions(n: int, counts: dict[str, int]) -> dict:
    return {name: fraction(count, n) for name, count in counts.items()}


def _asking(turns: Sequence[Reading]) -> dict:
    plain = [turn for turn in turns if turn.signals]
    formed = [turn for turn in turns if turn.asked_forms]
    either = [turn for turn in turns if turn.signals or turn.asked_forms]
    return {
        **_fractions(len(turns), {"plain_text": len(plain), "clarify": len(formed), "either": len(either)}),
        "started_by_machine": fraction(sum(t.author is Author.MACHINE for t in either), len(either)),
        "plain_signals": _fractions(len(plain), {s.value: sum(s in t.signals for t in plain) for s in Signal}),
    }


_COVERAGE = {
    "with_choices": (all, lambda q: bool(q.choices)),
    "without_choices": (all, lambda q: not q.choices),
    "with_send": (any, lambda q: q.has_send),
    "recommended_first": (all, lambda q: q.recommended_first),
    "real_options": (all, lambda q: q.real_options),
    "other_row": (all, lambda q: q.other_row),
}


def _clarify(turns: Sequence[Reading]) -> tuple[dict, dict]:
    forms = [form for turn in turns for form in turn.forms]
    asked = [form for form in forms if form.delivery is Delivery.ASKED and form.questions]
    questions = [question for form in asked for question in form.questions]
    counts = {
        "asked": len(asked),
        "rejected": sum(form.delivery is Delivery.REJECTED for form in forms),
        "not_shown": sum(form.delivery is Delivery.NOT_SHOWN for form in forms),
        "questions": len(questions),
    }
    coverage = {
        "calls": _fractions(len(asked), {name: sum(over(test(q) for q in form.questions) for form in asked)
                                         for name, (over, test) in _COVERAGE.items()}),
        "questions": _fractions(len(questions), {name: sum(map(test, questions))
                                                 for name, (_, test) in _COVERAGE.items()}),
    }
    return counts, coverage


@dataclass(frozen=True, slots=True)
class Ask:
    at: float
    conversation: int
    group: tuple[int, int, int]
    stem: str
    key: AskKey
    plain: bool


def _asks(conversations: Sequence[Sequence[Reading]]) -> list[Ask]:
    found = []
    for conversation, turns in enumerate(conversations):
        for turn_index, turn in enumerate(turns):
            if turn.author is Author.BOT:
                continue
            for form_index, form in enumerate(turn.asked_forms):
                group = (conversation, turn_index, form_index)
                found += [Ask(turn.at, conversation, group, q.text, AskKey.of(q.text, q.choices), False)
                          for q in form.questions]
            if turn.signals:
                stem = question_stem(turn.final_text)
                key = AskKey.of(stem, listed_options(turn.final_text, turn.signals))
                found.append(Ask(turn.at, conversation, (conversation, turn_index, -1), stem, key, True))
    return sorted(found, key=lambda ask: ask.at)


def _repeats(asks: Sequence[Ask], owner_turns: int) -> tuple[dict, list[tuple[str, int]]]:
    within = across = 0
    first_of: list[int] = []
    for index, ask in enumerate(asks):
        match = next((earlier for earlier in range(index - 1, -1, -1)
                      if asks[earlier].group != ask.group and ask.key.repeats(asks[earlier].key)), None)
        first_of.append(index if match is None else first_of[match])
        if match is not None:
            same = asks[match].conversation == ask.conversation
            within += same
            across += not same
    pairs = within + across
    counts = {"asks": len(asks), "pairs": pairs, "within_conversation": within, "across_conversations": across,
              "owner_turns": owner_turns,
              "per_100_owner_turns": round(100 * pairs / owner_turns, 2) if owner_turns else None}
    repeated = [(asks[first].stem, times) for first, times in Counter(first_of).most_common() if times > 1]
    return counts, repeated


def _followups(conversations: Sequence[Sequence[Reading]]) -> Iterable[tuple[Reading, Reading]]:
    for turns in conversations:
        yield from ((before, turn) for before, turn in pairwise(turns) if turn.author is Author.OWNER)


def _corrections(conversations: Sequence[Sequence[Reading]]) -> dict:
    followups = list(_followups(conversations))
    eligible = [turn for before, turn in followups
                if before.author is not Author.BOT and (before.changes or before.restated_steps)]
    shapes = [correction_shapes(turn.text) for turn in eligible]
    return {
        "after_action_or_restatement": fraction(sum(map(bool, shapes)), len(eligible)),
        "again_only": fraction(sum(says_again(turn.text) and not found for turn, found in zip(eligible, shapes)),
                                len(eligible)),
        "by_shape": dict(sorted(Counter(name for found in shapes for name in found).items())),
        "asking_behaviour": dict(sorted(Counter(
            name for turn in eligible for name in correction_classes(turn.text)).items())),
        "any_follow_up": fraction(sum(bool(correction_shapes(turn.text)) for _, turn in followups), len(followups)),
    }


def _work(conversations: Sequence[Sequence[Reading]]) -> dict:
    owner = changing = machine = machine_changing = unclassified_only = 0
    categories: Counter = Counter()
    covered: Counter = Counter()
    for turns in conversations:
        for before, turn in zip((None, *turns), turns):
            if turn.author is Author.MACHINE:
                machine += 1
                machine_changing += bool(turn.trigger_changes)
            if turn.author is not Author.OWNER:
                continue
            owner += 1
            if not turn.trigger_changes:
                unclassified_only += bool(turn.changes)
                continue
            changing += 1
            categories.update({change for _, change in turn.trigger_changes})
            first = turn.trigger_changes[0][0]
            asked = (any(form.position < first for form in turn.asked_forms)
                     or any(step <= first[0] for step in turn.question_steps))
            restated = any(step <= first[0] for step in turn.restated_steps)
            answering = before is not None and before.author is not Author.BOT and bool(before.signals)
            covered.update(asked_first=asked, restated_first=restated, answering_a_question=answering,
                           no_question_or_restatement=not (asked or restated or answering))
    return {
        "changing_turns": fraction(changing, owner),
        "by_category": _fractions(changing, {change.value: categories[change] for change in TRIGGER_CHANGES}),
        **_fractions(changing, {name: covered[name] for name in (
            "asked_first", "restated_first", "answering_a_question", "no_question_or_restatement")}),
        "unclassified_only_turns": fraction(unclassified_only, owner),
        "machine_changing_turns": fraction(machine_changing, machine),
    }


def _shape_rows(stems: Iterable[tuple[str, int]]) -> list[dict]:
    shapes: Counter = Counter()
    for stem, times in stems:
        shapes[redacted_shape(stem)] += times
    return [{"shape": shape, "times": times} for shape, times in shapes.most_common(SHAPE_LIMIT)]


def _profile(home: Path, since: float, shapes: bool) -> dict:
    transcripts = read_transcripts(home, since)
    conversations = [tuple(map(_read, turns)) for turns in transcripts.conversations]
    every = [turn for turns in conversations for turn in turns]
    to_owner = [turn for turn in every if turn.author is not Author.BOT]
    authors = Counter(turn.author for turn in every)
    asks = _asks(conversations)
    repeats, repeated = _repeats(asks, authors[Author.OWNER])
    clarify_calls, coverage = _clarify(to_owner)
    plain = [(ask.stem, 1) for ask in asks if ask.plain]
    return {
        "status": "ok",
        "conversations": len(conversations),
        "counted_sources": dict(transcripts.counted),
        "skipped_sessions": dict(transcripts.skipped),
        "turns": {author.value: authors[author] for author in Author},
        "asking": _asking(to_owner),
        "clarify_calls": clarify_calls,
        "form_coverage": coverage,
        "repeats": repeats,
        "corrections": _corrections(conversations),
        "work": _work(conversations),
        "shapes": {"repeated": _shape_rows(repeated) if shapes else [],
                   "plain": _shape_rows(plain) if shapes else []},
    }


def _owned_by_this_user(database: Path) -> bool:
    geteuid = getattr(os, "geteuid", None)
    return geteuid is None or database.stat().st_uid == geteuid()


@contextmanager
def scratch_home() -> Iterator[Path]:
    # Loading the current home's config creates its folders and SOUL.md, so no measured home may be current.
    with tempfile.TemporaryDirectory(prefix="hermes-eval-") as scratch:
        token = set_hermes_home_override(scratch)
        try:
            yield Path(scratch)
        finally:
            reset_hermes_home_override(token)


def bot_reports(targets: Sequence[tuple[str, Path]], read: Callable[[Path, Path], dict]) -> dict:
    bots = {}
    for name, home in targets:
        if not (home / "state.db").is_file():
            bots[name] = {"status": "no_store"}
            continue
        try:
            if not _owned_by_this_user(home / "state.db"):
                bots[name] = {"status": "not_store_owner"}
                continue
            with scratch_home() as scratch:
                bots[name] = read(home, scratch)
        except Exception as exc:  # health: allow BLE001 -- a store error can quote stored text, so only its type leaves the process
            bots[name] = {"status": "error", "error": type(exc).__name__}
    return bots


def window(days: int, now: float) -> dict:
    return {"days": days, "since": _iso(now - days * DAY), "until": _iso(now)}


def measure(targets: Sequence[tuple[str, Path]], *, days: int, now: float, shapes: bool = True) -> dict:
    since = now - days * DAY
    bots = bot_reports(targets, lambda home, _: _profile(home, since, shapes))
    return {"schema": SCHEMA, "stem_cap": STEM_CAP, "window": window(days, now), "bots": bots}


def _iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, UTC).isoformat(timespec="seconds")


_TABLE: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("asked in plain text", ("asking", "plain_text")),
    ("asked through clarify", ("asking", "clarify")),
    ("asked either way", ("asking", "either")),
    ("clarify calls with choices", ("form_coverage", "calls", "with_choices")),
    ("clarify calls without choices", ("form_coverage", "calls", "without_choices")),
    ("clarify calls recommended first", ("form_coverage", "calls", "recommended_first")),
    ("clarify calls with real options", ("form_coverage", "calls", "real_options")),
    ("clarify calls with Other row", ("form_coverage", "calls", "other_row")),
    ("clarify calls with send", ("form_coverage", "calls", "with_send")),
    ("corrected after action/restatement", ("corrections", "after_action_or_restatement")),
    ("only 'again' after action (weak)", ("corrections", "again_only")),
    ("owner turns that changed something", ("work", "changing_turns")),
    ("  asked first", ("work", "asked_first")),
    ("  restated first", ("work", "restated_first")),
    ("  answering a question", ("work", "answering_a_question")),
    ("  no question or restatement", ("work", "no_question_or_restatement")),
    ("only unclassified tools (shell etc.)", ("work", "unclassified_only_turns")),
)


def _row(label: str, count: object, n: object = "", share: float | None = None) -> str:
    shown = "" if share is None else f"{share:.1%}"
    return f"{label:<38}{count!s:>7}{n!s:>7}{shown:>8}"


def _table(name: str, bot: dict) -> list[str]:
    if bot["status"] != "ok":
        return [f"== {name}: {bot['status']} {bot.get('error', '')}".rstrip()]
    lines = [f"== {name}", _row("metric", "count", "n") + "   share",
             _row("conversations", bot["conversations"]), _row("owner turns", bot["turns"]["owner"])]
    for label, path in _TABLE:
        cell = bot
        for key in path:
            cell = cell[key]
        lines.append(_row(label, cell["count"], cell["n"], cell["share"]))
    repeats = bot["repeats"]
    rate = repeats["per_100_owner_turns"]
    lines.append(_row("repeated questions", repeats["pairs"], repeats["asks"]))
    lines.append(_row("repeats per 100 owner turns", "-" if rate is None else rate, repeats["owner_turns"]))
    return lines


def render(report: dict, *, json_only: bool = False) -> str:
    document = json.dumps(report, ensure_ascii=False, indent=1)
    if json_only:
        return document
    tables = [line for name, bot in report["bots"].items() for line in _table(name, bot)]
    return "\n".join([document, "", f"window: last {report['window']['days']} days", *tables])


def window_days(value: str) -> int:
    days = int(value)
    if days < 1:
        raise argparse.ArgumentTypeError("--days must be at least 1")
    return days


def profile_targets(profile: str | None) -> list[tuple[str, Path]] | None:
    if profile and not profile_exists(profile):
        print(f"unknown profile: {profile}", file=sys.stderr)
        return None
    names = (profile,) if profile else served_profiles()
    if not names:
        print("no served profile found; pass --profile", file=sys.stderr)
        return None
    return [(name, get_profile_dir(name)) for name in names]


def exit_status(report: dict) -> int:
    return int(any(bot["status"] in ("error", "not_store_owner") for bot in report["bots"].values()))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python evals/intent/baseline.py",
        description="Read-only counts of how bots ask the owner questions. Prints aggregates and redacted "
                    f"question shapes of at most {STEM_CAP} characters.")
    parser.add_argument("--profile", help="measure one profile (default: every served profile)")
    parser.add_argument("--days", type=window_days, default=14, help="window in days (default: 14)")
    parser.add_argument("--json", action="store_true", help="print the JSON report without the table")
    parser.add_argument("--no-shapes", action="store_true", help="print counts only, no question shapes")
    args = parser.parse_args(argv)
    targets = profile_targets(args.profile)
    if targets is None:
        return 2
    report = measure(targets, days=args.days, now=time.time(), shapes=not args.no_shapes)
    print(render(report, json_only=args.json))
    return exit_status(report)


if __name__ == "__main__":
    raise SystemExit(main())
