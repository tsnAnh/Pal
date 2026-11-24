from __future__ import annotations

import json
import statistics
from collections import Counter
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

from gateway.proactive_scorecard.patterns import (
    correction_classes, hands_back, is_bare_yes_no, matched_criteria, option_labels, question_count,
    question_text, states_default, states_recommendation,
)
from gateway.proactive_scorecard.rubric import RUBRIC_VERSION, Criterion, Label, label_from_criteria

SCHEMA = "proactive-eval-mine/1"
DEFAULT_EXCLUDED_SOURCES = ("kanban", "subagent", "tool", "cron")
CONTEXT_MESSAGES = 3
CHARS_PER_TOKEN = 4


@dataclass(frozen=True, slots=True)
class AskItem:
    question: str
    choices: tuple[str, ...] = ()
    recommend: bool = True
    default: str = ""


@dataclass(frozen=True, slots=True)
class Message:
    role: str
    text: str
    ts: float
    asks: tuple[AskItem, ...] = ()
    truth: Label | None = None


@dataclass(frozen=True, slots=True)
class MinedSession:
    bot: str
    started_at: float
    messages: tuple[Message, ...]


@dataclass(frozen=True, slots=True)
class QuestionContext:
    question: str
    recent: tuple[str, ...]


QuestionJudge = Callable[[QuestionContext], "frozenset[Criterion] | None"]


class SessionSource(Protocol):
    def sessions(self, since: float | None, until: float | None) -> Iterator[MinedSession]: ...


def _week_key(ts: float) -> str:
    iso = datetime.fromtimestamp(ts, UTC).isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def _ratio(numerator: int, denominator: int) -> float | None:
    return round(numerator / denominator, 4) if denominator else None


def _spread(values: Sequence[int]) -> dict:
    if not values:
        return {"n": 0, "mean": None, "median": None, "p90": None}
    ordered = sorted(values)
    p90 = ordered[min(len(ordered) - 1, round(0.9 * (len(ordered) - 1)))]
    return {"n": len(ordered), "mean": round(statistics.fmean(ordered), 2), "median": statistics.median(ordered),
            "p90": p90}


@dataclass(slots=True)
class Stats:
    sessions: int = 0
    open_sessions: int = 0
    owner_turns: int = 0
    assistant_turns: int = 0
    question_turns: int = 0
    avoidable: int = 0
    unclassified: int = 0
    corrections_after_question: int = 0
    truth_n: int = 0
    truth_agree: int = 0
    asks: int = 0
    batched_turns: int = 0
    asks_with_options: int = 0
    asks_recommended_first: int = 0
    asks_bare_yes_no: int = 0
    asks_no_options_no_default: int = 0
    handbacks: int = 0
    owner_tokens: int = 0
    done_owner_turns: list[int] = field(default_factory=list)
    criteria: Counter = field(default_factory=Counter)
    corrections: Counter = field(default_factory=Counter)

    def to_dict(self) -> dict:
        out = {
            "sessions": self.sessions, "open_sessions": self.open_sessions, "owner_turns": self.owner_turns,
            "assistant_turns": self.assistant_turns, "question_turns": self.question_turns,
            "avoidable": self.avoidable, "needed": self.question_turns - self.avoidable,
            "unclassified": self.unclassified,
            "avoidable_rate": _ratio(self.avoidable, self.question_turns),
            "question_rate": _ratio(self.question_turns, self.assistant_turns),
            "owner_turns_to_done": _spread(self.done_owner_turns),
            "ask_quality": {
                "asks": self.asks, "asks_per_task": _ratio(self.asks, self.sessions),
                "batched_turn_share": _ratio(self.batched_turns, self.question_turns),
                "with_options_share": _ratio(self.asks_with_options, self.asks),
                "recommended_first_share": _ratio(self.asks_recommended_first, self.asks_with_options),
                "bare_yes_no_share": _ratio(self.asks_bare_yes_no, self.asks_with_options),
                "no_options_no_default_share": _ratio(self.asks_no_options_no_default, self.asks),
            },
            "handbacks": self.handbacks,
            "owner_corrections_per_100_turns": round(100 * sum(self.corrections.values()) / self.owner_turns, 2)
            if self.owner_turns else None,
            "owner_tokens_per_task": round(self.owner_tokens / self.sessions, 1) if self.sessions else None,
            "criteria": dict(sorted(self.criteria.items())),
            "corrections": dict(sorted(self.corrections.items())),
            "corrections_total": sum(self.corrections.values()),
            "corrections_after_question": self.corrections_after_question,
        }
        if self.truth_n:
            out["heuristic_agreement"] = {"n": self.truth_n, "agree": self.truth_agree,
                                          "rate": _ratio(self.truth_agree, self.truth_n)}
        return out


def _question_of(message: Message) -> str | None:
    if message.role != "assistant":
        return None
    if message.asks:
        return "\n".join(item.question for item in message.asks)
    return question_text(message.text)


def _ask_items(message: Message) -> tuple[AskItem, ...]:
    if message.asks:
        return message.asks
    options = option_labels(message.text)
    count = question_count(message.text)
    first = AskItem(message.text[-300:], options, states_recommendation(options[0]) if options else False)
    return (first, *(AskItem(message.text[-300:]) for _ in range(count - 1)))


def _record_ask_quality(stats: Stats, message: Message) -> None:
    items = _ask_items(message)
    stats.asks += len(items)
    stats.batched_turns += len(items) >= 2
    for item in items:
        if item.choices:
            stats.asks_with_options += 1
            stats.asks_recommended_first += bool(item.recommend and (len(item.choices) >= 2 or states_recommendation(item.choices[0])))
            stats.asks_bare_yes_no += is_bare_yes_no(item.choices)
        elif not item.default and not states_default(f"{message.text}\n{item.question}"):
            stats.asks_no_options_no_default += 1


def _judged(session: MinedSession, index: int, question: str, judge: QuestionJudge | None):
    criteria = None
    if judge is not None:
        recent = tuple(m.text[-400:] for m in session.messages[max(0, index - CONTEXT_MESSAGES):index])
        criteria = judge(QuestionContext(question, recent))
    return label_from_criteria(criteria if criteria is not None else matched_criteria(question))


def _record_question(stats: Stats, verdict, message: Message) -> None:
    stats.question_turns += 1
    _record_ask_quality(stats, message)
    stats.avoidable += verdict.label is Label.AVOIDABLE
    stats.unclassified += verdict.basis == "default_needed"
    stats.criteria.update(c.value for c in verdict.criteria)
    if message.truth is not None:
        stats.truth_n += 1
        stats.truth_agree += message.truth is verdict.label


def _analyse(session: MinedSession, judge: QuestionJudge | None, buckets: dict[str, Stats], total: Stats) -> None:
    owner_turns = sum(1 for m in session.messages if m.role == "user")
    if not owner_turns:
        return
    week = buckets.setdefault(_week_key(session.started_at), Stats())
    last_was_question = False
    for index, message in enumerate(session.messages):
        handbacks = int(message.role == "assistant" and hands_back(message.text))
        typed = len(message.text) // CHARS_PER_TOKEN if message.role == "user" else 0
        for stats in (week, total):
            stats.assistant_turns += message.role == "assistant"
            stats.handbacks += handbacks
            stats.owner_tokens += typed
        question = _question_of(message)
        if question is not None:
            verdict = _judged(session, index, question, judge)
            for stats in (week, total):
                _record_question(stats, verdict, message)
        if message.role == "user" and index > 0:
            classes = correction_classes(message.text)
            for stats in (week, total):
                stats.corrections.update(classes)
                stats.corrections_after_question += bool(classes) and last_was_question
        last_was_question = question is not None
    last = session.messages[-1]
    finished = last.role == "assistant" and not last_was_question
    for stats in (week, total):
        stats.sessions += 1
        stats.owner_turns += owner_turns
        if finished:
            stats.done_owner_turns.append(owner_turns)
        else:
            stats.open_sessions += 1


def mine(sources: dict[str, SessionSource], *, since: float | None = None, until: float | None = None,
         judge: QuestionJudge | None = None, source_label: str = "store") -> dict:
    bots: dict[str, dict] = {}
    for bot, source in sources.items():
        weeks: dict[str, Stats] = {}
        total = Stats()
        for session in source.sessions(since, until):
            _analyse(session, judge, weeks, total)
        bots[bot] = {"total": total.to_dict(), "weeks": {k: weeks[k].to_dict() for k in sorted(weeks)}}
    return {
        "schema": SCHEMA, "rubric_version": RUBRIC_VERSION, "source": source_label,
        "judge": "model" if judge is not None else "heuristic",
        "window": {"since": since, "until": until}, "bots": bots,
    }


def _text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(p.get("text", "")) for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def _clarify_asks(tool_calls) -> tuple[AskItem, ...]:
    asks: list[AskItem] = []
    for call in tool_calls if isinstance(tool_calls, list) else ():
        function = call.get("function") if isinstance(call, dict) else None
        body = function or call or {}
        if body.get("name") != "clarify":
            continue
        arguments = body.get("arguments") or call.get("input")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError:
                arguments = None
        for item in (arguments or {}).get("questions") or ():
            if isinstance(item, dict) and str(item.get("question") or "").strip():
                choices = tuple(str(c) for c in item.get("choices") or () if str(c).strip())
                asks.append(AskItem(str(item["question"]).strip(), choices, item.get("recommend") is not False,
                                    str(item.get("default") or "").strip()))
    return tuple(asks)


class PersistenceSource:
    def __init__(self, target: str | Path, *, excluded_sources: Sequence[str] = DEFAULT_EXCLUDED_SOURCES,
                 limit: int = 500, bot: str = "") -> None:
        self._target, self._excluded, self._limit, self._bot = target, tuple(excluded_sources), limit, bot

    def sessions(self, since: float | None, until: float | None) -> Iterator[MinedSession]:
        from persistence.conversation.messages import TranscriptRead
        from persistence.conversation.sessions import RecentBrowseQuery
        from persistence_assembly import open_persistence_reader

        with open_persistence_reader(self._target) as store:
            store.ready()
            entries = store.sessions.list_recent_sessions(RecentBrowseQuery(
                limit=self._limit, exclude_sources=self._excluded, timeout_seconds=20.0))
            for entry in entries:
                if (since is not None and entry.started_at < since) or (until is not None and entry.started_at >= until):
                    continue
                rows = store.messages.read_transcript(entry.session_id, TranscriptRead(include_lineage=True))
                messages = tuple(
                    Message(row.role, _text_of(row.content), float(row.timestamp), _clarify_asks(row.tool_calls))
                    for row in rows
                    if row.role in ("user", "assistant") and not row.compressed_summary)
                if messages:
                    yield MinedSession(self._bot, float(entry.started_at), messages)


REACH_SCHEMA = "proactive-eval-reach/1"


def count_reach(rows: Sequence[dict]) -> dict:
    weeks: dict[str, dict[str, Counter]] = {}
    for row in rows:
        created = row.get("created_at")
        if not isinstance(created, (int, float)):
            continue
        cell = weeks.setdefault(_week_key(created), {}).setdefault(str(row.get("domain") or "unknown"), Counter())
        cell["offers"] += 1
        cell[f"status_{row.get('status') or 'unknown'}"] += 1
        cell[f"outcome_{row.get('outcome') or 'none'}"] += 1
    alerted = [c for domains in weeks.values() for c in domains.values()]
    acted, dismissed = sum(c["outcome_acted"] for c in alerted), sum(c["outcome_dismissed"] for c in alerted)
    return {
        "schema": REACH_SCHEMA, "rubric_version": RUBRIC_VERSION,
        "acted_share": _ratio(acted, acted + dismissed),
        "weeks": {week: {domain: dict(sorted(c.items())) for domain, c in sorted(domains.items())}
                  for week, domains in sorted(weeks.items())},
    }
