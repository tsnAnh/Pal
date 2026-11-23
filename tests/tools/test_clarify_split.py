import json
from types import SimpleNamespace

import pytest

from agent.turn_tool_round import _split_clarify_details
from tools.clarify_split import (
    NEUTRAL_QUESTION,
    OPTION_MAX_CHARS,
    QUESTION_MAX_CHARS,
    split_clarify_arguments,
    split_question,
)

LETTER = "Hi team,\n\nI have built three dashboards for fintech clients and can start Monday.\n\nBest,\nAnh"
PROPOSAL = f"Job: https://example.test/job/1\nRate: $50/h, fee 10%\n\nCover letter:\n{LETTER}\n\nSubmit this proposal?"


def _words(text):
    return "".join(text.split())


def test_short_question_is_untouched():
    assert split_question("Submit this proposal?") == ("", "Submit this proposal?")


def test_content_before_a_question_becomes_details():
    details, question = split_question(PROPOSAL)
    assert question == "Submit this proposal?"
    assert details.startswith("Job: https://example.test/job/1") and LETTER in details


def test_nothing_is_lost_or_truncated():
    details, question = split_question(PROPOSAL)
    assert _words(details + question) == _words(PROPOSAL)


def test_question_inside_the_last_paragraph_is_the_last_sentence():
    text = "I drafted the reply and checked the rate against the job post. Send it now?"
    long = text + " " + "x" * QUESTION_MAX_CHARS
    details, question = split_question(f"{long} Send it now?")
    assert question == "Send it now?" and details.startswith("I drafted")


def test_no_question_mark_uses_the_neutral_line_and_all_text_is_details():
    text = "Proposal ready.\n\nRate $50/h."
    assert split_question(text) == (text, NEUTRAL_QUESTION)


def test_over_long_single_line_is_details():
    text = "x" * (QUESTION_MAX_CHARS + 1) + "?"
    assert split_question(text) == (text, NEUTRAL_QUESTION)


@pytest.mark.parametrize("shape", ["Pick one:\n- a\n- b\nWhich?", "Run this?\n```\nrm -rf x\n```\nOK?"])
def test_lists_and_code_fences_are_split(shape):
    details, question = split_question(shape)
    assert details and len(question) <= QUESTION_MAX_CHARS


def _args(*texts, choices=("Approve", "Edit", "Cancel")):
    return json.dumps({"questions": [{"question": t, "choices": list(choices)} for t in texts]})


def test_arguments_keep_options_order_and_other_fields():
    raw, details = split_clarify_arguments(_args(PROPOSAL))
    item = json.loads(raw)["questions"][0]
    assert item == {"question": "Submit this proposal?", "choices": ["Approve", "Edit", "Cancel"]}
    assert LETTER in details


def test_short_arguments_come_back_as_given():
    raw = _args("Submit?")
    assert split_clarify_arguments(raw) == (raw, "")


def test_several_questions_each_split_details_in_order():
    first, second = "Alpha detail.\n\nFirst ok?", "Beta detail.\n\nSecond ok?"
    raw, details = split_clarify_arguments(_args(first, "Plain?", second))
    questions = [q["question"] for q in json.loads(raw)["questions"]]
    assert questions == ["First ok?", "Plain?", "Second ok?"]
    assert details == "Alpha detail.\n\nBeta detail."


def test_unparsable_arguments_are_left_alone():
    assert split_clarify_arguments("{not json") == ("{not json", "")


def _turn(arguments, content=""):
    call = SimpleNamespace(id="c1", function=SimpleNamespace(name="clarify", arguments=arguments))
    other = SimpleNamespace(id="c2", function=SimpleNamespace(name="terminal", arguments="{}"))
    message = SimpleNamespace(tool_calls=[call, other], content=content)
    row = {"role": "assistant", "content": content, "tool_calls": [
        {"id": "c1", "function": {"name": "clarify", "arguments": arguments}},
        {"id": "c2", "function": {"name": "terminal", "arguments": "{}"}}]}
    return message, row


def test_turn_row_carries_details_in_its_content_and_the_short_question_in_the_call():
    message, row = _turn(_args(PROPOSAL), content="On it.")
    _split_clarify_details(message, row)
    assert row["content"].startswith("On it.\n\nJob: https://example.test/job/1")
    assert json.loads(row["tool_calls"][0]["function"]["arguments"])["questions"][0]["question"] == "Submit this proposal?"
    assert json.loads(message.tool_calls[0].function.arguments) == json.loads(row["tool_calls"][0]["function"]["arguments"])
    assert row["tool_calls"][1]["function"]["arguments"] == "{}"


def test_turn_row_with_a_short_question_is_unchanged():
    message, row = _turn(_args("Submit?"), content="Ready.")
    before = json.dumps(row)
    _split_clarify_details(message, row)
    assert json.dumps(row) == before


def test_limits_are_one_line_each():
    assert OPTION_MAX_CHARS < QUESTION_MAX_CHARS
