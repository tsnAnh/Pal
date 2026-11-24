from __future__ import annotations

import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Mapping

RUBRIC_PATH = Path(__file__).with_name("rubric.json")


class Label(StrEnum):
    AVOIDABLE = "avoidable"
    NEEDED = "needed"


class Criterion(StrEnum):
    OWNER_ONLY = "owner_only"
    IRREVERSIBLE = "irreversible"
    COSTLY = "costly"
    APPROVAL_GATE = "approval_gate"
    LOOKUP_DECIDABLE = "lookup_decidable"
    SAFE_DEFAULT = "safe_default"
    REVERSIBLE = "reversible"


NEEDED_CRITERIA = frozenset({Criterion.OWNER_ONLY, Criterion.IRREVERSIBLE, Criterion.COSTLY, Criterion.APPROVAL_GATE})
AVOIDABLE_CRITERIA = frozenset({Criterion.LOOKUP_DECIDABLE, Criterion.SAFE_DEFAULT, Criterion.REVERSIBLE})


@dataclass(frozen=True, slots=True)
class Verdict:
    label: Label
    basis: str
    criteria: frozenset[Criterion]


def load_rubric() -> dict:
    return json.loads(RUBRIC_PATH.read_text(encoding="utf-8-sig"))


RUBRIC = load_rubric()
RUBRIC_VERSION: str = RUBRIC["version"]

_declared = {Criterion(name): spec["side"] for name, spec in RUBRIC["criteria"].items()}
if _declared != {**dict.fromkeys(NEEDED_CRITERIA, "needed"), **dict.fromkeys(AVOIDABLE_CRITERIA, "avoidable")}:
    raise RuntimeError("rubric.json and the Criterion enum disagree")


def parse_criteria(raw) -> frozenset[Criterion]:
    if isinstance(raw, Mapping):
        raw = [name for name, on in raw.items() if on]
    return frozenset(Criterion(str(name)) for name in (raw or ()))


def label_from_criteria(criteria: frozenset[Criterion]) -> Verdict:
    if criteria & NEEDED_CRITERIA:
        return Verdict(Label.NEEDED, "criteria", criteria)
    if criteria & AVOIDABLE_CRITERIA:
        return Verdict(Label.AVOIDABLE, "criteria", criteria)
    return Verdict(Label.NEEDED, "default_needed", criteria)


def render_markdown() -> str:
    lines = [f"### Rubric v{RUBRIC_VERSION}", "", f"Unit: {RUBRIC['unit']}", ""]
    lines += [f"- **{label.upper()}**: {text}" for label, text in RUBRIC["labels"].items()]
    lines += ["", RUBRIC["precedence"], "", "| Criterion | Side | Observable test |", "|---|---|---|"]
    lines += [f"| `{name}` | {spec['side']} | {spec['test']} |" for name, spec in RUBRIC["criteria"].items()]
    lines += ["", "| Metric | Definition |", "|---|---|"]
    lines += [f"| `{name}` | {text} |" for name, text in RUBRIC["metrics"].items()]
    lines += ["", f"**Ask quality.** {RUBRIC['ask_quality']['principle']}", "", "| Measure | Definition |", "|---|---|"]
    lines += [f"| `{name}` | {text} |" for name, text in RUBRIC["ask_quality"]["measures"].items()]
    return "\n".join(lines) + "\n"
