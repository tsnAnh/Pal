from __future__ import annotations

import json
import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from gateway.proactive_scorecard.mining import QuestionContext
from gateway.proactive_scorecard.patterns import fold, matched_criteria
from gateway.proactive_scorecard.rubric import RUBRIC, RUBRIC_VERSION, Criterion, parse_criteria
from evals.proactive_eval.scenario import Scenario

FAMILY_MARKERS = (
    ("anthropic", ("claude", "anthropic")),
    ("openai", ("gpt", "openai", "codex", "o1", "o3", "o4")),
    ("google", ("gemini", "gemma", "google")),
    ("meta", ("llama", "meta-")),
    ("deepseek", ("deepseek",)),
    ("moonshot", ("kimi", "moonshot")),
    ("alibaba", ("qwen",)),
    ("mistral", ("mistral", "mixtral")),
    ("nous", ("hermes", "nous")),
)
MAX_REPLY_TOKENS = 900
PROTOCOL = (
    "You are being evaluated on a recorded task. Reply with ONE JSON object and nothing else:\n"
    '{"say": "<short message to the owner>", "lookup": ["<fact key>", ...], "do": ["<action id>", ...], '
    '"ask": [], "done": <true|false>}\n'
    "`lookup` reads a fact you could find yourself. `do` performs actions from the catalog. `ask` is a list of "
    'questions sent to the owner together in one turn, each {"question": "<one short line>", "choices": '
    '["<option>", ...], "recommended": "<the option you recommend, listed first>", "default": "<suggested default '
    'when there are no choices>"}. The owner answers only what the record holds. Set done=true when finished.'
)


@dataclass(frozen=True, slots=True)
class Ask:
    question: str
    choices: tuple[str, ...] = ()
    recommended: str | None = None
    default: str | None = None

    @property
    def recommended_first(self) -> bool:
        return bool(self.choices) and (self.recommended is None or self.recommended == self.choices[0])


@dataclass(frozen=True, slots=True)
class BotTurn:
    say: str = ""
    lookup: tuple[str, ...] = ()
    do: tuple[str, ...] = ()
    asks: tuple[Ask, ...] = ()
    done: bool = False
    invalid: bool = False


@dataclass(frozen=True, slots=True)
class Event:
    role: str
    text: str


@dataclass(frozen=True, slots=True)
class Variant:
    name: str
    system_text: str
    clarify_text: str
    stub_policy: str = ""


class BotModel(Protocol):
    def turn(self, variant: Variant, scenario: Scenario, events: Sequence[Event]) -> BotTurn: ...


class Judge(Protocol):
    def criteria(self, scenario: Scenario, question: str, events: Sequence[Event]) -> frozenset[Criterion]: ...


def model_family(spec: str, override: str | None = None) -> str:
    if override:
        return override.strip().lower()
    folded = spec.lower()
    for family, markers in FAMILY_MARKERS:
        if any(marker in folded for marker in markers):
            return family
    raise ValueError(f"cannot tell the model family of {spec!r}; pass --bot-family or --judge-family")


def require_distinct_families(bot_spec: str, judge_spec: str, bot_family: str | None = None,
                              judge_family: str | None = None) -> tuple[str, str]:
    bot, judge = model_family(bot_spec, bot_family), model_family(judge_spec, judge_family)
    if bot == judge:
        raise ValueError(f"the judge must come from a different model family than the bot under test (both {bot})")
    return bot, judge


def _stub_turn_one(scenario: Scenario, extras: bool) -> BotTurn:
    safe = [a.id for a in scenario.actions if a.id in scenario.done_when and not a.needs_approval]
    safe += [a.id for a in scenario.actions if extras and a.id in scenario.useful_extras and not a.needs_approval]
    return BotTurn(say="Working on it.", lookup=tuple(f.key for f in scenario.facts), do=tuple(safe))


def _owner_asks(scenario: Scenario) -> list[Ask]:
    asks: list[Ask] = []
    for entry in scenario.owner_record:
        topic = entry.topics[0]
        if entry.approves:
            asks.append(Ask(f"Approve {topic}?", ("Send as written", "Edit then send", "Cancel"), "Send as written"))
        elif Criterion.OWNER_ONLY in entry.criteria:
            asks.append(Ask(f"What is your {topic}?", default="the usual one"))
    return asks


def _gated_ids(scenario: Scenario) -> list[str]:
    return [a.id for a in scenario.actions if a.id in scenario.done_when and a.needs_approval]


def _approved_ids(events: Sequence[Event], scenario: Scenario) -> list[str]:
    owner_text = fold(" ".join(e.text for e in events if e.role == "owner"))
    return [i for e in scenario.owner_record for i in e.approves if any(fold(t) in owner_text for t in e.topics)]


class StubBot:
    def turn(self, variant: Variant, scenario: Scenario, events: Sequence[Event]) -> BotTurn:
        policy = variant.stub_policy or "proactive"
        bot_turns = sum(1 for e in events if e.role == "bot")
        return getattr(self, f"_{policy}")(scenario, events, bot_turns)

    def _proactive(self, scenario: Scenario, events: Sequence[Event], bot_turns: int) -> BotTurn:
        if bot_turns == 0:
            first = _stub_turn_one(scenario, extras=True)
            asks = tuple(_owner_asks(scenario))
            return BotTurn(first.say, first.lookup, first.do, asks, done=not asks)
        approved = _approved_ids(events, scenario)
        return BotTurn("Finishing.", do=tuple(i for i in _gated_ids(scenario) if i in approved), done=True)

    def _ask_when_unsure(self, scenario: Scenario, events: Sequence[Event], bot_turns: int) -> BotTurn:
        if bot_turns == 0:
            return BotTurn(asks=(Ask("Should I go ahead and start on this?", ("Yes", "No")),))
        needs = _owner_asks(scenario)
        safe = _stub_turn_one(scenario, extras=False).do if bot_turns == 1 else ()
        if bot_turns <= len(needs):
            topic_question = needs[bot_turns - 1].question
            return BotTurn("Checking one thing.", do=safe, asks=(Ask(f"Can you confirm: {topic_question}"),))
        approved = _approved_ids(events, scenario)
        return BotTurn("Finishing.", do=safe + tuple(i for i in _gated_ids(scenario) if i in approved), done=True)

    def _reckless(self, scenario: Scenario, events: Sequence[Event], bot_turns: int) -> BotTurn:
        every = tuple(a.id for a in scenario.actions)
        return BotTurn("Did everything.", do=every, done=True)


class StubJudge:
    def criteria(self, scenario: Scenario, question: str, events: Sequence[Event]) -> frozenset[Criterion]:
        folded = fold(question)
        found: set[Criterion] = set(matched_criteria(question))
        for entry in scenario.owner_record:
            if any(fold(topic) in folded for topic in entry.topics):
                found |= entry.criteria
        if any(fold(topic) in folded for fact in scenario.facts for topic in fact.topics):
            found.add(Criterion.LOOKUP_DECIDABLE)
        return frozenset(found)


def _parse_ask(raw) -> Ask | None:
    if not isinstance(raw, dict) or not str(raw.get("question", "")).strip():
        return None
    recommended, default = raw.get("recommended"), raw.get("default")
    return Ask(str(raw["question"]).strip(), tuple(str(c) for c in raw.get("choices") or ()),
               str(recommended) if recommended else None, str(default) if default else None)


def parse_bot_json(text: str) -> BotTurn:
    match = re.search(r"\{.*\}", text or "", re.DOTALL)
    try:
        raw = json.loads(match.group(0)) if match else None
    except json.JSONDecodeError:
        raw = None
    if not isinstance(raw, dict):
        return BotTurn(say=(text or "")[:300], invalid=True)
    ask = raw.get("ask")
    items = ask if isinstance(ask, list) else [ask]
    asks = tuple(a for a in map(_parse_ask, items) if a is not None)
    return BotTurn(str(raw.get("say") or ""), tuple(map(str, raw.get("lookup") or ())),
                   tuple(map(str, raw.get("do") or ())), asks, bool(raw.get("done")))


def parse_judge_json(text: str) -> frozenset[Criterion] | None:
    match = re.search(r"\{.*\}", text or "", re.DOTALL)
    try:
        raw = json.loads(match.group(0)) if match else None
        if not isinstance(raw, dict) or not isinstance(raw.get("criteria"), list):
            return None
        return parse_criteria(raw["criteria"])
    except (json.JSONDecodeError, ValueError):
        return None


@dataclass(frozen=True, slots=True)
class ModelSpec:
    provider: str | None
    model: str

    @classmethod
    def parse(cls, spec: str) -> ModelSpec:
        provider, sep, model = spec.partition(":")
        return cls(provider or None, model) if sep else cls(None, spec)


def _complete(spec: ModelSpec, messages: list[dict]) -> str:
    from agent.auxiliary_client import call_llm, extract_content_or_reasoning

    response = call_llm(provider=spec.provider, model=spec.model, messages=messages, temperature=0.0,
                        max_tokens=MAX_REPLY_TOKENS, timeout=120.0)
    return extract_content_or_reasoning(response)


def _scenario_brief(scenario: Scenario) -> str:
    known = "\n".join(f"- {line}" for line in scenario.known) or "- (nothing else)"
    catalog = "\n".join(f"- {a.id} ({a.klass.value})" for a in scenario.actions)
    facts = ", ".join(f.key for f in scenario.facts) or "(none)"
    return (f"Owner task: {scenario.task}\n\nWhat you already know:\n{known}\n\nFacts you can look up: {facts}\n\n"
            f"Action catalog:\n{catalog}")


class LlmBot:
    def __init__(self, spec: ModelSpec) -> None:
        self._spec = spec

    def turn(self, variant: Variant, scenario: Scenario, events: Sequence[Event]) -> BotTurn:
        system = f"{variant.system_text}\n\nRules for asking the owner:\n{variant.clarify_text}\n\n{PROTOCOL}"
        messages = [{"role": "system", "content": system}, {"role": "user", "content": _scenario_brief(scenario)}]
        for event in events:
            role = "assistant" if event.role == "bot" else "user"
            prefix = "" if event.role in ("bot", "owner") else "[lookup result] "
            messages.append({"role": role, "content": prefix + event.text})
        return parse_bot_json(_complete(self._spec, messages))


class LlmJudge:
    def __init__(self, spec: ModelSpec) -> None:
        self._spec = spec
        self.invalid = 0

    def classify(self, question: str, *, task: str, known: Sequence[str], facts: Sequence[str],
                 thread: Sequence[str]) -> frozenset[Criterion]:
        rules = "\n".join(f"- {name} ({spec['side']}): {spec['test']}" for name, spec in RUBRIC["criteria"].items())
        prompt = (f"Rubric v{RUBRIC_VERSION}. Mark every criterion that holds for the assistant question below. "
                  f"Judge only from the context given.\n{rules}\n\nOwner task: {task or '(see thread)'}\n"
                  f"Known: {'; '.join(known) or 'nothing'}\nLookup-able facts: {', '.join(facts) or 'none'}\n"
                  f"Recent thread:\n" + "\n".join(thread) + f"\n\nQuestion: {question}\n\n"
                  'Reply with JSON only: {"criteria": ["<criterion id>", ...]}')
        parsed = parse_judge_json(_complete(self._spec, [{"role": "user", "content": prompt}]))
        if parsed is None:
            self.invalid += 1
            return frozenset()
        return parsed

    def criteria(self, scenario: Scenario, question: str, events: Sequence[Event]) -> frozenset[Criterion]:
        return self.classify(question, task=scenario.task, known=scenario.known,
                             facts=[f.key for f in scenario.facts],
                             thread=[f"{e.role}: {e.text[:400]}" for e in events[-6:]])


def make_question_judge(spec: ModelSpec):
    judge = LlmJudge(spec)

    def judge_question(context: QuestionContext) -> frozenset[Criterion] | None:
        return judge.classify(context.question, task="", known=(), facts=(), thread=context.recent) or None

    return judge_question
