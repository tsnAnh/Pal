"""scripts/ci/check_swift_clarify_settled.py: a settled clarify card draws only the question and the chosen rows."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_clarify_settled.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_clarify_settled as cs

SETTLED = (
    "struct ClarifySettledCard: View {\n    let settled: ClarifySettled\n    var body: some View {\n"
    "        VStack {\n            ForEach(settled.entries) { entry in Text(entry.question) }\n        }\n    }\n}\n"
)
OLD_ANSWERED = (
    "struct ClarifyAnsweredCard: View {\n    var body: some View {\n        VStack {\n"
    "            ClarifyRow(letter: nil, text: pick, style: .chosen)\n        }\n    }\n}\n"
)
ROW_CONTENT = (
    "struct ClarifyRowContent: View {\n    var body: some View {\n        switch kind {\n"
    "        case .clarifyAnswered(let records):\n            %s\n"
    "        case .clarify(let prompt):\n            ClarifyCard(prompt: prompt) { _ in }\n        default:\n            EmptyView()\n        }\n    }\n}\n"
)


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_a_settled_card_with_only_the_question_and_chosen_rows_passes(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ClarifySettledCard.swift": SETTLED})
    assert cs.scan(root) == []


def test_an_answered_card_that_draws_a_row_fails_and_names_the_line(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ClarifyCards.swift": OLD_ANSWERED})
    found = cs.scan(root)
    assert len(found) == 1 and found[0].startswith("App/Chat/ClarifyCards.swift:4:") and "ClarifyRow" in found[0]


def test_letters_badges_buttons_and_the_full_choices_list_fail_in_a_settled_card(tmp_path):
    for needle in ("ClarifyBadge(letter: \"A\", style: .choice)", "ForEach(prompt.choices) { Text($0) }",
                   "Button(\"Done\") { }", "ClarifyInputRow(letter: \"C\")", "ClarifyRow.letter(0)"):
        body = SETTLED.replace("Text(entry.question)", needle)
        root = _tree(tmp_path, {"App/Chat/ClarifySettledCard.swift": body})
        assert len(cs.scan(root)) == 1, needle


def test_the_answered_branch_of_the_row_content_may_not_draw_the_live_card(tmp_path):
    clean = _tree(tmp_path, {"App/Chat/ClarifyFormCard.swift": ROW_CONTENT % "ClarifySettledCard(settled: settled)"})
    assert cs.scan(clean) == []
    bad = _tree(tmp_path, {"App/Chat/ClarifyFormCard.swift": ROW_CONTENT % "ClarifyFormCard(prompt: prompt) { _ in }"})
    found = cs.scan(bad)
    assert len(found) == 1 and ":5:" in found[0] and "clarifyAnswered branch" in found[0]


def test_the_live_card_may_draw_every_option(tmp_path):
    live = "struct ClarifyCard: View {\n    var body: some View {\n        ForEach(prompt.choices) { ClarifyRow(letter: nil, text: $0) }\n    }\n}\n"
    assert cs.scan(_tree(tmp_path, {"App/Chat/ClarifyCards.swift": live})) == []


def test_the_real_tree_is_clean():
    assert cs.scan(REPO / "apps" / "ios") == []
