from __future__ import annotations

import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from evals.proactive_eval.rubric import Criterion, parse_criteria

SCENARIO_ROOT = Path(__file__).with_name("scenarios")


class Split(StrEnum):
    TUNE = "tune"
    HELDOUT = "heldout"


class ActionClass(StrEnum):
    REVERSIBLE_EDIT = "reversible_edit"
    RUN_TOOL = "run_tool"
    CREATE_FILE = "create_file"
    SCHEDULE = "schedule"
    SPEND = "spend"
    MESSAGE_PEOPLE = "message_people"


class ScenarioError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Fact:
    key: str
    value: str
    topics: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Action:
    id: str
    klass: ActionClass
    reversible: bool
    outbound: bool
    credential: bool

    @property
    def needs_approval(self) -> bool:
        return self.outbound or self.credential or not self.reversible or self.klass is ActionClass.SPEND


@dataclass(frozen=True, slots=True)
class OwnerEntry:
    topics: tuple[str, ...]
    answer: str
    criteria: frozenset[Criterion]
    approves: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Scenario:
    id: str
    split: Split
    task: str
    known: tuple[str, ...]
    facts: tuple[Fact, ...]
    actions: tuple[Action, ...]
    done_when: tuple[str, ...]
    useful_extras: tuple[str, ...]
    owner_record: tuple[OwnerEntry, ...]

    def action(self, action_id: str) -> Action | None:
        return next((a for a in self.actions if a.id == action_id), None)


def _strings(raw, where: str) -> tuple[str, ...]:
    if not isinstance(raw, list) or not all(isinstance(item, str) and item.strip() for item in raw):
        raise ScenarioError(f"{where} must be a list of non-empty strings")
    return tuple(raw)


def _field(raw: dict, key: str, where: str):
    if key not in raw:
        raise ScenarioError(f"{where}: missing {key!r}")
    return raw[key]


def _parse_action(raw: dict, where: str) -> Action:
    try:
        klass = ActionClass(_field(raw, "class", where))
    except ValueError as exc:
        raise ScenarioError(f"{where}: {exc}") from exc
    flags = {name: bool(raw.get(name, default)) for name, default in
             (("reversible", True), ("outbound", klass is ActionClass.MESSAGE_PEOPLE), ("credential", False))}
    return Action(str(_field(raw, "id", where)), klass, **flags)


def _parse_owner_entry(raw: dict, where: str) -> OwnerEntry:
    try:
        criteria = parse_criteria(raw.get("criteria"))
    except ValueError as exc:
        raise ScenarioError(f"{where}: {exc}") from exc
    return OwnerEntry(_strings(_field(raw, "topics", where), f"{where}.topics"), str(_field(raw, "answer", where)),
                      criteria, tuple(raw.get("approves") or ()))


def parse_scenario(raw: dict, *, where: str = "scenario") -> Scenario:
    try:
        split = Split(_field(raw, "split", where))
    except ValueError as exc:
        raise ScenarioError(f"{where}: {exc}") from exc
    facts = tuple(Fact(str(_field(f, "key", where)), str(_field(f, "value", where)),
                       _strings(_field(f, "topics", where), f"{where}.facts.topics")) for f in raw.get("facts") or ())
    actions = tuple(_parse_action(a, f"{where}.actions") for a in _field(raw, "actions", where))
    owner = tuple(_parse_owner_entry(e, f"{where}.owner_record") for e in raw.get("owner_record") or ())
    scenario = Scenario(
        id=str(_field(raw, "id", where)), split=split, task=str(_field(raw, "task", where)),
        known=_strings(raw.get("known", []), f"{where}.known"), facts=facts, actions=actions,
        done_when=_strings(_field(raw, "done_when", where), f"{where}.done_when"),
        useful_extras=_strings(raw.get("useful_extras", []), f"{where}.useful_extras"), owner_record=owner)
    _check_references(scenario, where)
    return scenario


def _check_references(scenario: Scenario, where: str) -> None:
    ids = [a.id for a in scenario.actions]
    if len(set(ids)) != len(ids):
        raise ScenarioError(f"{where}: duplicate action ids")
    known = set(ids)
    referenced = [*scenario.done_when, *scenario.useful_extras, *(i for e in scenario.owner_record for i in e.approves)]
    missing = sorted(set(referenced) - known)
    if missing:
        raise ScenarioError(f"{where}: unknown action ids {missing}")
    if set(scenario.done_when) & set(scenario.useful_extras):
        raise ScenarioError(f"{where}: an action cannot be both required and an unprompted extra")
    if not scenario.done_when:
        raise ScenarioError(f"{where}: done_when is empty")


def load_scenarios(split: Split, root: Path = SCENARIO_ROOT) -> tuple[Scenario, ...]:
    folder = root / split.value
    loaded: list[Scenario] = []
    for path in sorted(folder.glob("*.json")):
        try:
            scenario = parse_scenario(json.loads(path.read_text(encoding="utf-8")), where=path.name)
        except json.JSONDecodeError as exc:
            raise ScenarioError(f"{path.name}: {exc}") from exc
        if scenario.split is not split:
            raise ScenarioError(f"{path.name}: split {scenario.split.value!r} sits in the {split.value!r} folder")
        if scenario.id != path.stem:
            raise ScenarioError(f"{path.name}: id {scenario.id!r} must equal the file name")
        loaded.append(scenario)
    return tuple(loaded)
