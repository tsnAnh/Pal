"""The ledger's prompt rule has one home: gateway.commitments.PROMPT_RULE, imported into the owner guidance, and
each of its sentences appears exactly once in every rendered stock prompt."""

import re
from pathlib import Path

import pytest

from agent.prompt_builder import OWNER_PROACTIVE_GUIDANCE
from gateway.commitments import PROMPT_RULE

PROMPTS = sorted((Path(__file__).resolve().parents[1] / "fixtures" / "prompt_surface" / "prompts").glob("*.txt"))


def sentences(text: str) -> list[str]:
    return [part.strip() for part in re.split(r"(?<=[.!?])\s+", text) if len(part.strip()) > 20]


def test_the_owner_guidance_carries_the_rule_once():
    assert OWNER_PROACTIVE_GUIDANCE.count(PROMPT_RULE) == 1


def test_every_stock_prompt_is_rendered():
    assert len(PROMPTS) == 9


@pytest.mark.parametrize("prompt", PROMPTS, ids=lambda p: p.stem)
def test_each_rule_sentence_appears_once_in_the_assembled_prompt(prompt):
    text = prompt.read_text(encoding="utf-8")
    assert text.count(PROMPT_RULE) == 1
    for sentence in sentences(PROMPT_RULE):
        assert text.count(sentence) == 1, sentence
