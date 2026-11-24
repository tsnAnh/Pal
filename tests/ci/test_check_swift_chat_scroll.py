"""scripts/ci/check_swift_chat_scroll.py: the chat list scrolls vertically only; iOS pins it to the viewport width, Mac never does."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_chat_scroll.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_chat_scroll as css

VIEW = (
    "struct ChatView: View {\n"
    "    var chat: some View {\n"
    "        ScrollView {\n"
    "            rows\n"
    "                .chatColumn()\n"
    "                #if os(iOS)\n"
    "                .containerRelativeFrame(.horizontal)\n"
    "                #endif\n"
    "        }\n"
    "    }\n"
    "}\n"
)
PRE_FIX_VIEW = (
    "struct ChatView: View {\n"
    "    var chat: some View {\n"
    "        ScrollView {\n"
    "            rows\n"
    "                .padding(.horizontal, ChatMetrics.edgeMargin)\n"
    "                .chatColumn()\n"
    "                .containerRelativeFrame(.horizontal)\n"
    "        }\n"
    "    }\n"
    "}\n"
)
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
    for name, body in {"App/Chat/ChatTranscriptList.swift": view, "App/Chat/ChatScrollController.swift": controller}.items():
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


def test_a_list_without_the_ios_width_pin_fails(tmp_path):
    root = _tree(tmp_path, view=VIEW.replace("                .containerRelativeFrame(.horizontal)\n", ""))
    found = css.scan(root)
    assert len(found) == 1 and "iOS" in found[0] and "viewport width" in found[0]


def test_the_pin_in_the_mac_build_fails_naming_the_line_and_the_fix(tmp_path):
    found = css.scan(_tree(tmp_path, view=PRE_FIX_VIEW))
    assert len(found) == 1
    assert found[0].startswith("App/Chat/ChatTranscriptList.swift:7:")
    assert "macOS build" in found[0] and "#if os(iOS)" in found[0] and ".chatColumn()" in found[0]


def test_a_pin_behind_a_mac_only_branch_fails_and_an_ios_or_else_branch_passes(tmp_path):
    mac_only = VIEW.replace("#if os(iOS)", "#if os(macOS)")
    assert any("macOS build" in entry for entry in css.scan(_tree(tmp_path / "a", view=mac_only)))
    ios_else = VIEW.replace("#if os(iOS)", "#if os(macOS)\n                .frame(maxWidth: .infinity)\n                #else")
    assert css.scan(_tree(tmp_path / "b", view=ios_else)) == []


TARGETED_VIEW = (
    "struct ChatView: View {\n"
    "    var chat: some View {\n"
    "        ScrollView {\n"
    "            LazyVStack {\n"
    "                rows.chatListRow()\n"
    "            }\n"
    "            .scrollTargetLayout()\n"
    "            .coordinateSpace(.named(space))\n"
    "            #if os(iOS)\n"
    "            .containerRelativeFrame(.horizontal)\n"
    "            #endif\n"
    "        }\n"
    "        .scrollPosition($position)\n"
    "        .padding(.horizontal, 4)\n"
    "    }\n"
    "}\n"
)


def test_rows_carrying_their_own_margins_pass(tmp_path):
    assert css.scan(_tree(tmp_path, view=TARGETED_VIEW)) == []


def test_margins_or_a_column_around_the_scroll_target_layout_fail_naming_the_line(tmp_path):
    for modifier in (".padding(.horizontal, ChatMetrics.edgeMargin)", ".chatColumn()"):
        view = TARGETED_VIEW.replace("            .coordinateSpace(.named(space))\n", f"            .coordinateSpace(.named(space))\n            {modifier}\n")
        found = css.scan(_tree(tmp_path / modifier[1:8], view=view))
        assert len(found) == 1, modifier
        assert found[0].startswith("App/Chat/ChatTranscriptList.swift:9:") and ".chatListRow()" in found[0]


def test_the_opt_out_marker_waives_the_line(tmp_path):
    root = _tree(tmp_path, controller=CONTROLLER.replace("position.scrollTo(y: 12)", "position.scrollTo(x: 0) // chat-scroll: ok"))
    assert css.scan(root) == []


def test_the_real_tree_is_clean():
    assert css.scan(REPO / "apps" / "ios") == []


TICK_CONTROLLER_PRE_FIX = (
    "final class ChatScrollController {\n"
    "    func observe(_ geometry: ScrollGeometry) {\n"
    "        if abs(previous - snapshot.containerWidth) > Self.restoreTolerance {\n"
    "            rowHeights.widthChanged()\n"
    "            measureTick &+= 1\n"
    "        }\n"
    "    }\n"
    "}\n"
)
TICK_CONTROLLER = (
    "final class ChatScrollController {\n"
    "    func observe(_ geometry: ScrollGeometry) {\n"
    "        if abs(previous - snapshot.containerWidth) > Self.restoreTolerance {\n"
    "            widthMoved()\n"
    "        }\n"
    "    }\n"
    "    private func widthMoved() {\n"
    "        rowHeights.widthChanged()\n"
    "        measureTick &+= 1\n"
    "    }\n"
    "}\n"
)


def test_row_heights_invalidated_on_every_width_tick_fail(tmp_path):
    found = css.scan(_tree(tmp_path, controller=TICK_CONTROLLER_PRE_FIX))
    assert len(found) == 2
    assert all("every width tick" in entry for entry in found)


def test_a_width_change_that_settles_once_after_the_drag_passes(tmp_path):
    assert css.scan(_tree(tmp_path, controller=TICK_CONTROLLER)) == []
