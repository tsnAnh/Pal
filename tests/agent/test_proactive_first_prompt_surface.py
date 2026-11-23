"""Permanent regression for the "proactive first" principle on the model-facing prompt surface.

Reads the committed prompt-surface snapshot (the system prompts a stock install sends on each surface and the
``tools[]`` schemas), so it describes the current prompt as the baseline without regenerating a fixture.
"""

import json

import pytest

from agent.prompt_builder import OWNER_PROACTIVE_GUIDANCE
from evals.proactive_eval import prompt_surface as ps
from tools.clarify_tool import (
    CLARIFY_SCHEMA,
    MAX_CHOICES,
    MAX_QUESTIONS,
    RECOMMENDED_LABEL,
    clarify_tool,
)
from tools.clarify_split import OPTION_MAX_CHARS

SURFACES = ps.surfaces()

STUCK_THEN_ASK_FINDING = (
    "Baseline finding: TASK_COMPLETION_GUIDANCE (agent/prompt_builder.py) tells a stuck bot to try "
    "'different approach, ask the user'. That contradicts the principle block's 'Never hand your owner your "
    "stuck work'. Step 2 of proactive-first rewrites it; this strict xfail then flips and must be removed."
)

BAD_SAMPLES = {
    "doubt_then_ask": "When in doubt, ask the user what they want.",
    "always_ask_first": "Always ask your owner before you touch a file.",
    "ask_for_lookup": "Ask the user for the file path before you start.",
    "confirm_every_step": "Confirm with the user before each step.",
    "stuck_then_ask": "Try another approach, then ask the user to help.",
    "hand_over_command": "Tell the user to run the install command.",
}


def test_every_surface_is_covered():
    assert {"cli.claude", "telegram.claude", "cron.claude", "desktop.claude"} <= set(SURFACES)


@pytest.mark.parametrize("surface", SURFACES)
def test_the_principle_block_is_in_the_stable_tier_exactly_once(surface):
    stable = ps.stable_tier(surface)
    assert stable.count(OWNER_PROACTIVE_GUIDANCE) == 1
    assert stable.count(ps.PRINCIPLE_HEADING) == 1
    assert ps.prompt_text(surface).count(OWNER_PROACTIVE_GUIDANCE) == 1


@pytest.mark.parametrize("pattern_id", [a.id for a in ps.ANTI_PATTERNS if a.id != "stuck_then_ask"])
def test_no_prompt_text_tells_the_bot_to_ask_for_what_it_can_decide(pattern_id):
    hits = [(surface, sentence) for surface in SURFACES
            for found, sentence in ps.violations(ps.prompt_text(surface)) if found == pattern_id]
    assert not hits, hits[:3]


@pytest.mark.xfail(strict=True, reason=STUCK_THEN_ASK_FINDING)
def test_a_stuck_bot_is_never_told_to_hand_the_work_back_to_the_owner():
    hits = [(surface, sentence) for surface in SURFACES
            for found, sentence in ps.violations(ps.prompt_text(surface)) if found == "stuck_then_ask"]
    assert not hits, hits[:1]


def test_no_tool_description_tells_the_bot_to_ask_for_what_it_can_decide():
    hits = []
    for path in sorted((ps.SNAPSHOT / "tools").glob("*.json")):
        description = json.loads(path.read_text(encoding="utf-8")).get("description", "")
        hits += [(path.name, found) for found, _sentence in ps.violations(description)]
    assert not hits, hits


@pytest.mark.parametrize("pattern_id", sorted(BAD_SAMPLES))
def test_the_detector_fails_on_each_anti_pattern(pattern_id):
    assert pattern_id in {found for found, _ in ps.violations(BAD_SAMPLES[pattern_id])}


def test_a_negated_sentence_is_not_flagged():
    assert not ps.violations("Never ask your owner which model or effort a bot runs; read your runtime.")
    assert not ps.violations("Do not ask the user for the file path; search for it.")


def test_every_anti_pattern_has_a_sample_and_a_reason():
    assert {a.id for a in ps.ANTI_PATTERNS} == set(BAD_SAMPLES)
    assert all(a.why for a in ps.ANTI_PATTERNS)


def test_the_committed_clarify_schema_still_enforces_one_short_question_plus_options():
    assert ps.clarify_failures(ps.tool_schema("clarify")) == []


def test_the_live_clarify_schema_still_enforces_one_short_question_plus_options():
    assert ps.clarify_failures(CLARIFY_SCHEMA) == []
    questions = CLARIFY_SCHEMA["parameters"]["properties"]["questions"]
    assert questions["maxItems"] == MAX_QUESTIONS
    assert questions["items"]["properties"]["choices"]["maxItems"] == MAX_CHOICES


def test_the_detector_flags_a_clarify_schema_that_lost_its_rules():
    weakened = json.loads(json.dumps(CLARIFY_SCHEMA))
    weakened["description"] = "Ask the user anything."
    del weakened["parameters"]["properties"]["questions"]["items"]["properties"]["choices"]["maxItems"]
    failures = ps.clarify_failures(weakened)
    assert any("ONE short question line" in f for f in failures)
    assert any("choices lost its maxItems" in f for f in failures)


def _answering(reply_for):
    def callback(shown):
        return {"answers": {q["qid"]: reply_for(q) for q in shown}, "outcome": "submitted"}
    return callback


def test_clarify_rejects_an_option_that_carries_the_content():
    result = json.loads(clarify_tool(
        [{"question": "Send it?", "choices": ["Yes", "x" * (OPTION_MAX_CHARS + 1)]}], callback=_answering(lambda q: "Yes")))
    assert "limit is" in result["error"]


def test_clarify_caps_the_options_and_puts_the_recommended_one_first():
    seen = []

    def callback(shown):
        seen.extend(shown)
        return {"answers": {"q0": "A"}, "outcome": "submitted"}

    result = json.loads(clarify_tool(
        [{"question": "Which plan?", "choices": ["A", "B", "C", "D", "E", "F"]}], callback=callback))
    assert len(seen[0]["choices"]) == MAX_CHOICES
    assert seen[0]["choices"][0] == f"A {RECOMMENDED_LABEL}"
    assert result["responses"][0]["user_response"] == "A"


def test_clarify_takes_several_independent_questions_in_one_call():
    assert "error" in json.loads(clarify_tool([{"question": f"q{i}?"} for i in range(MAX_QUESTIONS + 1)],
                                              callback=_answering(lambda q: "x")))
    ok = json.loads(clarify_tool([{"question": "a?"}, {"question": "b?"}], callback=_answering(lambda q: "x")))
    assert [r["status"] for r in ok["responses"]] == ["answered", "answered"]


DUPLICATED_RULE_FINDING = (
    "Baseline finding: the two-bubble rule (send the details as a normal message, then ONE short question line "
    "and the options only, never paste the content into the question or an option) is written in both "
    "OWNER_PROACTIVE_GUIDANCE (agent/prompt_builder.py:406-408) and the clarify description "
    "(tools/clarify_tool.py:171-175). One home per fact: step 2 keeps it in the clarify text only."
)
MISSING_DEFAULT_RULE_FINDING = (
    "Baseline finding: the clarify text allows an open-ended question ('omit choices') and says nothing about a "
    "suggested default, so a bare open question is legal. Step 2 adds the rule and a default field."
)


def test_the_choices_rule_is_stated_once_in_the_clarify_text():
    text = ps.clarify_text(CLARIFY_SCHEMA)
    assert ps.choices_rule_count(text, "put your recommended option FIRST") == 1
    assert ps.choices_rule_count(text, "Options go ONLY in `choices`") == 1
    assert ps.choices_rule_count(text, "ONE short question line") == 2


@pytest.mark.xfail(strict=True, reason=DUPLICATED_RULE_FINDING)
def test_the_principle_block_and_the_clarify_text_share_no_sentence():
    assert ps.duplicated_sentences(OWNER_PROACTIVE_GUIDANCE, ps.clarify_text(CLARIFY_SCHEMA)) == []


@pytest.mark.xfail(strict=True, reason=MISSING_DEFAULT_RULE_FINDING)
def test_a_question_without_choices_carries_a_suggested_default():
    assert not ps.open_question_rule_missing(CLARIFY_SCHEMA)


def test_the_duplicate_detector_catches_a_reworded_copy_and_ignores_a_different_sentence():
    original = "To ask your owner to approve, first send the details as a normal message, then call clarify with the options only."
    reworded = "To ask the owner to approve, first send the details as a normal message, then call this with the options only (labels up to 80 characters)."
    assert ps.duplicated_sentences(original, reworded)
    assert not ps.duplicated_sentences(original, "Prefer deciding low-stakes questions yourself and keep going.")


def test_the_default_rule_detector_accepts_a_schema_that_names_one():
    schema = json.loads(json.dumps(CLARIFY_SCHEMA))
    schema["description"] += " A question without choices carries a suggested default."
    assert not ps.open_question_rule_missing(schema)
