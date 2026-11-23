from __future__ import annotations

import logging
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from types import MappingProxyType

logger = logging.getLogger(__name__)


class ActionClass(StrEnum):
    REVERSIBLE_EDITS = "reversible_edits"
    RUN_TOOLS = "run_tools"
    CREATE_FILES = "create_files"
    SCHEDULE_JOBS = "schedule_jobs"
    SPEND_MONEY = "spend_money"
    MESSAGE_PEOPLE = "message_people"


class Level(StrEnum):
    ACT = "act"
    ACT_AND_TELL = "act_and_tell"
    ASK = "ask"


_STRICTNESS = {level: rank for rank, level in enumerate(Level)}

DEFAULTS: Mapping[ActionClass, Level] = MappingProxyType({
    ActionClass.REVERSIBLE_EDITS: Level.ACT,
    ActionClass.RUN_TOOLS: Level.ACT,
    ActionClass.CREATE_FILES: Level.ACT,
    ActionClass.SCHEDULE_JOBS: Level.ACT_AND_TELL,
    ActionClass.SPEND_MONEY: Level.ASK,
    ActionClass.MESSAGE_PEOPLE: Level.ASK,
})

FLOORS: Mapping[ActionClass, Level] = MappingProxyType({
    ActionClass.SPEND_MONEY: Level.ASK,
    ActionClass.MESSAGE_PEOPLE: Level.ASK,
})

_PHRASES: Mapping[ActionClass, str] = MappingProxyType({
    ActionClass.REVERSIBLE_EDITS: "reversible edits",
    ActionClass.RUN_TOOLS: "running tools",
    ActionClass.CREATE_FILES: "creating files",
    ActionClass.SCHEDULE_JOBS: "scheduling jobs",
    ActionClass.SPEND_MONEY: "spending money",
    ActionClass.MESSAGE_PEOPLE: "messaging people",
})

_CLAUSES: Mapping[Level, str] = MappingProxyType({
    Level.ACT: "act on {} without asking",
    Level.ACT_AND_TELL: "act on {}, then tell your owner",
    Level.ASK: "ask your owner before {}",
})


@dataclass(frozen=True, slots=True)
class Autonomy:
    levels: Mapping[ActionClass, Level]
    clamped: frozenset[ActionClass]


def _parse(key, value) -> tuple[ActionClass, Level] | None:
    try:
        action = ActionClass(str(key).strip().lower())
    except ValueError:
        logger.warning("proactive.autonomy.%s: not an action class (%s); ignored", key, "|".join(ActionClass))
        return None
    try:
        return action, Level(str(value).strip().lower())
    except ValueError:
        logger.warning("proactive.autonomy.%s: %r is not %s; ignored", key, value, "|".join(Level))
        return None


def load_autonomy(cfg) -> Autonomy:
    section = cfg.get("proactive") if isinstance(cfg, Mapping) else None
    raw = section.get("autonomy") if isinstance(section, Mapping) else None
    levels = dict(DEFAULTS)
    clamped: set[ActionClass] = set()
    for key, value in (raw.items() if isinstance(raw, Mapping) else ()):
        parsed = _parse(key, value)
        if parsed is None:
            continue
        action, level = parsed
        floor = FLOORS.get(action)
        if floor is not None and _STRICTNESS[level] < _STRICTNESS[floor]:
            logger.warning("proactive.autonomy.%s: %s is below the %s floor; clamped", action, level, floor)
            level = floor
            clamped.add(action)
        levels[action] = level
    return Autonomy(MappingProxyType(levels), frozenset(clamped))


def _joined(phrases: list[str]) -> str:
    return phrases[0] if len(phrases) == 1 else ", ".join(phrases[:-1]) + " and " + phrases[-1]


def prompt_line(autonomy: Autonomy) -> str:
    clauses = []
    for level in Level:
        phrases = [_PHRASES[action] for action in ActionClass if autonomy.levels[action] is level]
        if phrases:
            clauses.append(_CLAUSES[level].format(_joined(phrases)))
    return "Autonomy by action class: " + "; ".join(clauses) + "."
