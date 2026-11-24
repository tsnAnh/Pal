import pytest

from gateway.proactive_scorecard import patterns, rubric
from gateway.proactive_scorecard.rubric import Criterion, Label


@pytest.mark.parametrize("criteria, label, basis", [
    ({Criterion.LOOKUP_DECIDABLE}, Label.AVOIDABLE, "criteria"),
    ({Criterion.SAFE_DEFAULT, Criterion.REVERSIBLE}, Label.AVOIDABLE, "criteria"),
    ({Criterion.OWNER_ONLY}, Label.NEEDED, "criteria"),
    ({Criterion.OWNER_ONLY, Criterion.LOOKUP_DECIDABLE}, Label.NEEDED, "criteria"),
    ({Criterion.APPROVAL_GATE, Criterion.SAFE_DEFAULT}, Label.NEEDED, "criteria"),
    (set(), Label.NEEDED, "default_needed"),
])
def test_label_follows_the_precedence_in_the_rubric(criteria, label, basis):
    verdict = rubric.label_from_criteria(frozenset(criteria))
    assert (verdict.label, verdict.basis) == (label, basis)


def test_rubric_file_and_enum_name_the_same_criteria():
    assert set(rubric.RUBRIC["criteria"]) == {c.value for c in Criterion}
    assert rubric.NEEDED_CRITERIA.isdisjoint(rubric.AVOIDABLE_CRITERIA)


def test_markdown_carries_the_version_every_criterion_and_every_metric():
    text = rubric.render_markdown()
    assert f"v{rubric.RUBRIC_VERSION}" in text
    assert all(f"`{name}`" in text for name in (*rubric.RUBRIC["criteria"], *rubric.RUBRIC["metrics"]))


@pytest.mark.parametrize("text", [
    "Done. Should I go ahead and merge it?",
    "I can do either.\n1. Rename now\n2. Rename later\nWhich do you want?",
    "Anh muốn tôi tiếp tục không?",
    "Ready? 🙂",
])
def test_question_turns_are_detected(text):
    assert patterns.question_text(text)


@pytest.mark.parametrize("text", [
    "Done. The tests pass.",
    "Is it fixed? I checked and it is.",
    "Options considered:\n1. A\n2. B\nI picked A.",
    "",
])
def test_statements_are_not_question_turns(text):
    assert patterns.question_text(text) is None


@pytest.mark.parametrize("text, expected", [
    ("Should I go ahead and run the tests?", Criterion.SAFE_DEFAULT),
    ("What is the path of the config file?", Criterion.LOOKUP_DECIDABLE),
    ("Can you send me the password for the vault?", Criterion.OWNER_ONLY),
    ("Do you want me to delete the old branch?", Criterion.IRREVERSIBLE),
    ("Bạn có muốn tôi tiếp tục không?", Criterion.SAFE_DEFAULT),
])
def test_criteria_lexicons_match_in_english_and_vietnamese(text, expected):
    assert expected in patterns.matched_criteria(text)


@pytest.mark.parametrize("text, expected", [
    ("Only ask me what is needed", "ask_only_needed"),
    ("chỉ hỏi những gì cần thiết thôi", "ask_only_needed"),
    ("chi hoi nhung gi can thiet", "ask_only_needed"),
    ("I already told you, don't ask again", "do_not_reconfirm"),
    ("đừng hỏi lại nữa", "do_not_reconfirm"),
    ("just do it", "just_do_it"),
    ("cứ làm đi", "just_do_it"),
    ("tự quyết đi", "decide_yourself"),
    ("it's in the repo, check it up yourself", "look_it_up"),
    ("be more proactive", "be_proactive"),
    ("too many options, give me one", "too_many_options"),
    ("why did you send that email", "overreach_complaint"),
])
def test_owner_corrections_match_by_pattern_class(text, expected):
    assert expected in patterns.correction_classes(text)


def test_a_neutral_owner_message_matches_no_correction_class():
    assert patterns.correction_classes("Thanks, that looks right.") == frozenset()


def test_correction_class_names_never_contain_message_text():
    assert all(name.replace("_", "").isalpha() for name in patterns.CORRECTION_PATTERNS)
