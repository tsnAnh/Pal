"""scripts/ci/check_swift_chat_scroll.py: the chat list scrolls vertically only and is pinned to the viewport width."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_chat_scroll.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_chat_scroll as css

VIEW = "struct ChatView: View {\n    var chat: some View {\n        ScrollView { rows.chatColumn().containerRelativeFrame(.horizontal) }\n    }\n}\n"
CONTROLLER = (
    "final class ChatScrollController {\n"
    "    static let revealAnchor = UnitPoint(x: 0, y: 0.5)\n"
    "    func go() {\n"
    "        position.scrollTo(edge: .top)\n"
    "        position.scrollTo(y: 12)\n"
    "        position.scrollTo(id: id, anchor: Self.revealAnchor)\n"
    "    }\n"
    "}\n"
)


def _tree(tmp_path: Path, view: str = VIEW, controller: str = CONTROLLER) -> Path:
    for name, body in {"App/ChatView.swift": view, "App/Chat/ChatScrollController.swift": controller}.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_vertical_only_scrolls_and_a_pinned_width_pass(tmp_path):
    assert css.scan(_tree(tmp_path)) == []


def test_a_centred_reveal_anchor_fails_and_names_the_line(tmp_path):
    root = _tree(tmp_path, controller=CONTROLLER.replace("anchor: Self.revealAnchor", "anchor: .center"))
    found = css.scan(root)
    assert len(found) == 1 and found[0].startswith("App/Chat/ChatScrollController.swift:6:")


def test_a_horizontal_target_fails(tmp_path):
    for call in ("position.scrollTo(x: 0)", "position.scrollTo(edge: .leading)", "position.scrollTo(point: .zero)"):
        root = _tree(tmp_path, controller=CONTROLLER.replace("position.scrollTo(y: 12)", call))
        assert len(css.scan(root)) == 1, call


def test_a_list_without_the_width_pin_fails(tmp_path):
    root = _tree(tmp_path, view=VIEW.replace(".containerRelativeFrame(.horizontal)", ""))
    found = css.scan(root)
    assert len(found) == 1 and "viewport width" in found[0]


def test_the_opt_out_marker_waives_the_line(tmp_path):
    root = _tree(tmp_path, controller=CONTROLLER.replace("position.scrollTo(y: 12)", "position.scrollTo(x: 0) // chat-scroll: ok"))
    assert css.scan(root) == []


def test_the_real_tree_is_clean():
    assert css.scan(REPO / "apps" / "ios") == []
