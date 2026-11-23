from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

SNAPSHOT = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "prompt_surface"
PRINCIPLE_HEADING = "# Working for your owner"
_SENTENCE_BREAK = re.compile(r"(?<=[.!?;])\s+|\n+")
_NEGATION = re.compile(r"\b(never|do not|don't|not|no need|without)\b", re.IGNORECASE)
_OWNER = r"(?:the user|your owner|the owner|your human)"


@dataclass(frozen=True, slots=True)
class AntiPattern:
    id: str
    why: str
    pattern: re.Pattern


def _anti(id: str, why: str, regex: str) -> AntiPattern:
    return AntiPattern(id, why, re.compile(regex, re.IGNORECASE))


ANTI_PATTERNS: tuple[AntiPattern, ...] = (
    _anti("doubt_then_ask", "turns uncertainty into a question instead of a stated assumption",
          r"\b(?:when|if) (?:you are |you're )?(?:in doubt|unsure|uncertain|not sure)\b[^.\n]{0,40}\bask\b"),
    _anti("always_ask_first", "asks before every action, reversible or not",
          rf"\balways (?:ask|confirm with|check with) {_OWNER}\b"),
    _anti("ask_for_lookup", "asks the owner for something a tool or a file already holds",
          rf"\bask {_OWNER} (?:for|which|what) (?:the )?(?:file|path|url|link|version|name|model|effort|branch|command|folder)\b"),
    _anti("confirm_every_step", "asks for confirmation at every step",
          rf"\b(?:confirm|check) with {_OWNER} (?:before|after) (?:every|each|any)\b"),
    _anti("stuck_then_ask", "hands the stuck work back to the owner instead of trying another route",
          rf"\b(?:different|another|alternative) (?:approach|route|way|package manager)\b[^.\n]{{0,40}}\bask {_OWNER}\b"),
    _anti("hand_over_command", "asks the owner to run a command the bot can run",
          rf"\b(?:tell|ask) {_OWNER} to run\b"),
)


def violations(text: str) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for sentence in _SENTENCE_BREAK.split(text):
        if _NEGATION.search(sentence):
            continue
        found += [(a.id, sentence.strip()) for a in ANTI_PATTERNS if a.pattern.search(sentence)]
    return found


def prompt_text(surface: str, root: Path = SNAPSHOT) -> str:
    return (root / "prompts" / f"{surface}.txt").read_text(encoding="utf-8")


def stable_tier(surface: str, root: Path = SNAPSHOT) -> str:
    text = prompt_text(surface, root)
    start = text.index("===== stable =====")
    following = [i for i in (text.find("===== context ====="), text.find("===== volatile =====")) if i > start]
    return text[start:min(following)] if following else text[start:]


def surfaces(root: Path = SNAPSHOT) -> list[str]:
    return sorted(path.stem for path in (root / "prompts").glob("*.txt"))


def tool_schema(name: str, root: Path = SNAPSHOT) -> dict:
    return json.loads((root / "tools" / f"{name}.json").read_text(encoding="utf-8"))


def clarify_failures(schema: dict) -> list[str]:
    description = schema.get("description", "")
    questions = schema["parameters"]["properties"]["questions"]
    item = questions["items"]
    failures = []
    for needle in ("ONE short question line", "options only", "Never paste the content", "Prefer deciding low-stakes"):
        if needle not in description:
            failures.append(f"description lost {needle!r}")
    if "ONE short question line" not in questions.get("description", ""):
        failures.append("questions description lost the one-short-line rule")
    if item["required"] != ["question"]:
        failures.append("question is no longer the only required field")
    if "choices" not in item["properties"] or "maxItems" not in item["properties"]["choices"]:
        failures.append("choices lost its maxItems bound")
    if "maxItems" not in questions:
        failures.append("questions lost its maxItems bound")
    return failures


_NEAR_DUPLICATE = 0.8
_MIN_WORDS = 6


def _normalised_sentences(text: str) -> list[list[str]]:
    out = []
    for sentence in _SENTENCE_BREAK.split(text):
        words = re.sub(r"[^\w` ]", " ", sentence.lower()).split()
        if len(words) >= _MIN_WORDS:
            out.append(words)
    return out


def _overlap(left: list[str], right: list[str]) -> float:
    import difflib

    blocks = difflib.SequenceMatcher(None, left, right, autojunk=False).get_matching_blocks()
    return sum(block.size for block in blocks) / min(len(left), len(right))


def duplicated_sentences(first: str, second: str) -> list[str]:
    right = _normalised_sentences(second)
    return [" ".join(a) for a in _normalised_sentences(first)
            if any(_overlap(a, b) >= _NEAR_DUPLICATE for b in right)]


def clarify_text(schema: dict) -> str:
    questions = schema["parameters"]["properties"]["questions"]
    return "\n".join([schema.get("description", ""), questions.get("description", "")])


def choices_rule_count(text: str, needle: str) -> int:
    return text.lower().count(needle.lower())


def open_question_rule_missing(schema: dict) -> bool:
    text = clarify_text(schema).lower()
    return not ("suggested default" in text or "default answer" in text or "default option" in text)
