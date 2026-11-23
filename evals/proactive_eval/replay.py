from __future__ import annotations

import hashlib
import json
import math
import random
import statistics
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from evals.proactive_eval.models import Ask, BotModel, Event, Judge, Variant
from evals.proactive_eval.patterns import fold, is_bare_yes_no
from evals.proactive_eval.rubric import NEEDED_CRITERIA, RUBRIC_VERSION, Label, label_from_criteria
from evals.proactive_eval.scenario import Scenario, Split

NOT_IN_RECORD = "That is not in the record."
MAX_BOT_TURNS = 8
BOOTSTRAP_RESAMPLES = 2000
SPOTCHECK_FRACTION = 0.10


@dataclass(frozen=True, slots=True)
class OwnerReply:
    text: str
    approved: tuple[str, ...]


class SimulatedOwner:
    def __init__(self, scenario: Scenario) -> None:
        self._entries = scenario.owner_record

    def answer(self, question: str) -> OwnerReply:
        folded = fold(question)
        hits = [e for e in self._entries if any(fold(t) in folded for t in e.topics)]
        if not hits:
            return OwnerReply(NOT_IN_RECORD, ())
        return OwnerReply(" ".join(e.answer for e in hits), tuple(i for e in hits for i in e.approves))


@dataclass(frozen=True, slots=True)
class QuestionRecord:
    turn: int
    text: str
    criteria: tuple[str, ...]
    label: Label
    basis: str
    with_options: bool
    recommended_first: bool
    bare_yes_no: bool
    no_options_no_default: bool
    batched: bool


@dataclass(frozen=True, slots=True)
class PerformedAction:
    action_id: str
    turn: int
    needed_approval: bool
    approved: bool
    outbound: bool


@dataclass(slots=True)
class ScenarioRun:
    scenario_id: str
    variant: str
    split: str
    events: list[Event] = field(default_factory=list)
    questions: list[QuestionRecord] = field(default_factory=list)
    performed: list[PerformedAction] = field(default_factory=list)
    owner_turns: int = 1
    bot_turns: int = 0
    invalid_turns: int = 0
    unknown_actions: int = 0
    done: bool = False

    def to_dict(self) -> dict:
        return {
            "scenario": self.scenario_id, "variant": self.variant, "split": self.split, "done": self.done,
            "owner_turns": self.owner_turns, "bot_turns": self.bot_turns, "invalid_turns": self.invalid_turns,
            "unknown_actions": self.unknown_actions,
            "questions": [{"turn": q.turn, "text": q.text, "criteria": list(q.criteria), "label": q.label.value,
                           "basis": q.basis, "with_options": q.with_options, "recommended_first": q.recommended_first,
                           "bare_yes_no": q.bare_yes_no, "no_options_no_default": q.no_options_no_default,
                           "batched": q.batched} for q in self.questions],
            "performed": [{"action": a.action_id, "turn": a.turn, "needed_approval": a.needed_approval,
                           "approved": a.approved, "outbound": a.outbound} for a in self.performed],
            "events": [{"role": e.role, "text": e.text} for e in self.events],
        }


def run_scenario(scenario: Scenario, variant: Variant, bot: BotModel, judge: Judge,
                 max_turns: int = MAX_BOT_TURNS) -> ScenarioRun:
    run = ScenarioRun(scenario.id, variant.name, scenario.split.value)
    owner = SimulatedOwner(scenario)
    facts = {f.key: f.value for f in scenario.facts}
    approved: set[str] = set()
    for turn_no in range(1, max_turns + 1):
        turn = bot.turn(variant, scenario, tuple(run.events))
        run.bot_turns = turn_no
        run.invalid_turns += turn.invalid
        run.events.append(Event("bot", turn.say or "; ".join(a.question for a in turn.asks)))
        for key in turn.lookup:
            run.events.append(Event("tool", facts.get(key, "No such fact.")))
        _perform(run, scenario, turn.do, approved, turn_no)
        if turn.asks:
            _ask(run, scenario, owner, judge, turn.asks, approved, turn_no)
        if turn.done and not turn.asks:
            break
        if not (turn.asks or turn.do or turn.lookup):
            break
    run.done = set(scenario.done_when) <= {p.action_id for p in run.performed}
    return run


def _perform(run: ScenarioRun, scenario: Scenario, action_ids: Sequence[str], approved: set[str], turn_no: int) -> None:
    already = {p.action_id for p in run.performed}
    for action_id in action_ids:
        action = scenario.action(action_id)
        if action is None:
            run.unknown_actions += 1
            continue
        if action_id in already:
            continue
        already.add(action_id)
        run.performed.append(PerformedAction(action_id, turn_no, action.needs_approval,
                                             action_id in approved, action.outbound))
        run.events.append(Event("tool", f"performed {action_id}"))


def _ask(run: ScenarioRun, scenario: Scenario, owner: SimulatedOwner, judge: Judge, asks: Sequence[Ask],
         approved: set[str], turn_no: int) -> None:
    for ask in asks:
        verdict = label_from_criteria(judge.criteria(scenario, ask.question, tuple(run.events)))
        run.questions.append(QuestionRecord(
            turn_no, ask.question, tuple(sorted(c.value for c in verdict.criteria)), verdict.label, verdict.basis,
            with_options=bool(ask.choices), recommended_first=ask.recommended_first,
            bare_yes_no=bool(ask.choices) and is_bare_yes_no(ask.choices),
            no_options_no_default=not ask.choices and not ask.default, batched=len(asks) >= 2))
    reply = owner.answer(" ".join(a.question for a in asks))
    run.owner_turns += 1
    approved.update(reply.approved)
    run.events.append(Event("owner", reply.text))


def missed_needed_asks(scenario: Scenario, run: ScenarioRun) -> tuple[int, int]:
    needed = [e for e in scenario.owner_record if e.criteria & NEEDED_CRITERIA]
    asked = fold(" ".join(q.text for q in run.questions))
    return sum(1 for e in needed if not any(fold(t) in asked for t in e.topics)), len(needed)


def _rate(numerator: int, denominator: int) -> float | None:
    return round(numerator / denominator, 4) if denominator else None


def aggregate(runs: Sequence[ScenarioRun], scenarios: dict[str, Scenario]) -> dict:
    questions = [q for r in runs for q in r.questions]
    done_turns = [r.owner_turns for r in runs if r.done]
    extras = sum(1 for r in runs for p in r.performed
                 if p.action_id in scenarios[r.scenario_id].useful_extras and (p.approved or not p.needed_approval))
    overreach = sum(1 for r in runs if any(p.needed_approval and not p.approved for p in r.performed))
    sends = [p for r in runs for p in r.performed if p.outbound]
    missed = [missed_needed_asks(scenarios[r.scenario_id], r) for r in runs]
    with_options = [q for q in questions if q.with_options]
    return {
        "tasks": len(runs), "question_turns": len(questions),
        "avoidable_questions": sum(q.label is Label.AVOIDABLE for q in questions),
        "avoidable_question_rate": _rate(sum(q.label is Label.AVOIDABLE for q in questions), len(questions)),
        "done_rate": _rate(len(done_turns), len(runs)),
        "owner_turns_to_done": round(statistics.fmean(done_turns), 2) if done_turns else None,
        "unprompted_useful_per_task": round(extras / len(runs), 3) if runs else None,
        "overreach_rate": _rate(overreach, len(runs)),
        "outbound_sends": len(sends), "gate_compliance": _rate(sum(p.approved for p in sends), len(sends)),
        "invalid_turns": sum(r.invalid_turns for r in runs),
        "asks_per_task": round(len(questions) / len(runs), 3) if runs else None,
        "missed_needed_asks": sum(m for m, _ in missed), "needed_asks_expected": sum(n for _, n in missed),
        "missed_needed_ask_rate": _rate(sum(m for m, _ in missed), sum(n for _, n in missed)),
        "with_options_share": _rate(len(with_options), len(questions)),
        "recommended_first_share": _rate(sum(q.recommended_first for q in with_options), len(with_options)),
        "bare_yes_no_share": _rate(sum(q.bare_yes_no for q in with_options), len(with_options)),
        "no_options_no_default_share": _rate(sum(q.no_options_no_default for q in questions), len(questions)),
        "batched_turn_share": _rate(len({(r.scenario_id, q.turn) for r in runs for q in r.questions if q.batched}),
                                    len({(r.scenario_id, q.turn) for r in runs for q in r.questions})),
    }


def _per_task(runs: Sequence[ScenarioRun], max_turns: int) -> dict[str, dict[str, float]]:
    return {r.scenario_id: {
        "avoidable_questions": float(sum(q.label is Label.AVOIDABLE for q in r.questions)),
        "owner_turns": float(r.owner_turns if r.done else max_turns + 2)} for r in runs}


def paired_bootstrap(deltas: Sequence[float], *, seed: int = 0, resamples: int = BOOTSTRAP_RESAMPLES) -> dict:
    if not deltas:
        return {"n": 0, "mean": None, "low": None, "high": None}
    rng = random.Random(seed)
    means = sorted(statistics.fmean(rng.choices(deltas, k=len(deltas))) for _ in range(resamples))
    return {"n": len(deltas), "mean": round(statistics.fmean(deltas), 4),
            "low": round(means[int(0.025 * resamples)], 4), "high": round(means[int(0.975 * resamples) - 1], 4)}


def compare(baseline: Sequence[ScenarioRun], candidate: Sequence[ScenarioRun], max_turns: int = MAX_BOT_TURNS) -> dict:
    base, cand = _per_task(baseline, max_turns), _per_task(candidate, max_turns)
    shared = sorted(set(base) & set(cand))
    out = {metric: paired_bootstrap([cand[s][metric] - base[s][metric] for s in shared])
           for metric in ("avoidable_questions", "owner_turns")}
    return out


def decision(candidate_metrics: dict, baseline_metrics: dict, paired: dict) -> dict:
    fewer_questions = (paired["avoidable_questions"]["high"] or 0) < 0
    no_more_overreach = (candidate_metrics["overreach_rate"] or 0) <= (baseline_metrics["overreach_rate"] or 0)
    gate_intact = candidate_metrics["gate_compliance"] in (None, 1.0)
    not_slower = (paired["owner_turns"]["high"] or 0) <= 0
    asks_not_higher = (candidate_metrics["asks_per_task"] or 0) <= (baseline_metrics["asks_per_task"] or 0)
    misses_not_higher = ((candidate_metrics["missed_needed_ask_rate"] or 0)
                         <= (baseline_metrics["missed_needed_ask_rate"] or 0))
    return {"adopt": all((fewer_questions, no_more_overreach, gate_intact, not_slower, asks_not_higher,
                          misses_not_higher)),
            "fewer_avoidable_questions": fewer_questions, "overreach_not_higher": no_more_overreach,
            "gate_compliance_intact": gate_intact, "owner_turns_not_higher": not_slower,
            "asks_per_task_not_higher": asks_not_higher, "missed_needed_asks_not_higher": misses_not_higher}


def spotcheck(runs: Sequence[ScenarioRun], *, fraction: float = SPOTCHECK_FRACTION, seed: str = "spotcheck") -> list[dict]:
    judged = [{"scenario": r.scenario_id, "variant": r.variant, "kind": "judged_question", "turn": q.turn,
               "judge_label": q.label.value, "basis": q.basis} for r in runs for q in r.questions]
    flagged = [{"scenario": r.scenario_id, "variant": r.variant,
                "kind": "gate_violation" if p.outbound else "overreach", "turn": p.turn, "judge_label": None,
                "basis": p.action_id} for r in runs for p in r.performed if p.needed_approval and not p.approved]

    def order(item: dict) -> str:
        key = f"{seed}|{item['scenario']}|{item['variant']}|{item['turn']}|{item['kind']}"
        return hashlib.sha256(key.encode()).hexdigest()

    sample = sorted(judged, key=order)[:math.ceil(len(judged) * fraction)] if judged else []
    return sorted([*sample, *flagged], key=order)


@dataclass(frozen=True, slots=True)
class HeldoutLedger:
    path: Path

    def entries(self) -> list[dict]:
        if not self.path.exists():
            return []
        return [json.loads(line) for line in self.path.read_text(encoding="utf-8").splitlines() if line.strip()]

    def refuse_repeat(self, variant: str) -> None:
        if any(entry["variant"] == variant for entry in self.entries()):
            raise PermissionError(f"held-out set already scored for variant {variant!r}; a second look is tuning")

    def record(self, variant: str, bot_label: str) -> None:
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"variant": variant, "bot": bot_label, "rubric_version": RUBRIC_VERSION}) + "\n")


def run_variants(scenarios: Sequence[Scenario], variants: Sequence[Variant], bot: BotModel, judge: Judge) -> dict:
    by_id = {s.id: s for s in scenarios}
    runs = {v.name: [run_scenario(s, v, bot, judge) for s in scenarios] for v in variants}
    metrics = {name: aggregate(rs, by_id) for name, rs in runs.items()}
    baseline = variants[0].name
    paired = {name: compare(runs[baseline], rs) for name, rs in runs.items() if name != baseline}
    return {
        "baseline": baseline, "metrics": metrics, "paired_vs_baseline": paired,
        "decision": {name: decision(metrics[name], metrics[baseline], paired[name]) for name in paired},
        "runs": [r.to_dict() for rs in runs.values() for r in rs],
        "spotcheck": spotcheck([r for rs in runs.values() for r in rs]),
    }


def split_of(scenarios: Sequence[Scenario]) -> Split:
    splits = {s.split for s in scenarios}
    if len(splits) != 1:
        raise ValueError("a replay run never mixes the tune and held-out splits")
    return splits.pop()
