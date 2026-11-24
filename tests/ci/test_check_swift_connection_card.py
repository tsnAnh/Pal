"""scripts/ci/check_swift_connection_card.py: no chat card asks the owner to Allow or Deny a connector."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_connection_card.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_connection_card as cc

CARD = 'struct ConnectionRequestCard: View {\n    var body: some View {\n        Button("Try again") { retry() }\n    }\n}\n'
ALLOW_CARD = CARD.replace('"Try again"', '"Allow"')
DENY_CARD = CARD.replace('"Try again"', 'String(localized: "Don\'t allow")')
ALLOW_ONCE = CARD.replace('"Try again"', '"Allow once"')
DECISION_TRY_AGAIN = "public enum ConnectionDecision: Sendable, Hashable {\n    case tryAgain\n}\n"
DECISION_ALLOW = "public enum ConnectionDecision: Sendable, Hashable {\n    case allow\n    case deny\n    case tryAgain\n}\n"
DECISION_FILE = "Packages/PalKit/Sources/PalChat/ConnectionCard.swift"


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_a_card_with_only_try_again_passes(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ChatCards.swift": CARD, DECISION_FILE: DECISION_TRY_AGAIN})
    assert cc.scan(root) == []


def test_an_allow_or_deny_label_in_a_chat_card_fails_and_names_the_line(tmp_path):
    for body in (ALLOW_CARD, DENY_CARD, ALLOW_ONCE, CARD.replace('"Try again"', '"Deny"')):
        root = _tree(tmp_path, {"App/Chat/ChatCards.swift": body})
        found = cc.scan(root)
        assert len(found) == 1 and found[0].startswith("App/Chat/ChatCards.swift:3:")


def test_a_sentence_that_only_starts_with_allow_is_not_a_button(tmp_path):
    root = _tree(tmp_path, {"App/Chat/Speech/Listener.swift": 'Text("Allow microphone access in Settings to use voice.")\n'})
    assert cc.scan(root) == []


def test_the_decision_enum_may_not_regain_allow_or_deny(tmp_path):
    root = _tree(tmp_path, {DECISION_FILE: DECISION_ALLOW})
    found = cc.scan(root)
    assert len(found) == 2 and all(line.startswith(f"{DECISION_FILE}:") for line in found)


def test_sending_a_decision_or_tapping_its_identifier_fails_anywhere_in_the_app(tmp_path):
    root = _tree(tmp_path, {
        "App/Rooms/RoomView.swift": "model.answerConnection(decision: ConnectionDecision.allow)\n",
        "App/Other.swift": 'Button("Go").accessibilityIdentifier("connectionDeny-x")\n',
    })
    assert len(cc.scan(root)) == 2


def test_an_allowlisted_card_is_skipped_and_others_are_not(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ChatDeskCardView.swift": ALLOW_CARD, "App/Chat/ChatCards.swift": ALLOW_CARD})
    assert [line.split(":")[0] for line in cc.scan(root)] == ["App/Chat/ChatCards.swift"]
    assert cc.ALLOWLIST.get("App/Chat/ChatDeskCardView.swift")


def test_the_real_tree_is_clean():
    assert cc.scan(REPO / "apps" / "ios") == []
