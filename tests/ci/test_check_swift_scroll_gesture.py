"""scripts/ci/check_swift_scroll_gesture.py: on iOS a row drag goes through ScrollSafePan so the scroll view's pan wins."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_scroll_gesture.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_scroll_gesture as csg

MAIN_6D1891D4_BUBBLE = (
    "#if os(iOS)\n"
    "private struct TouchMessageActions: ViewModifier {\n"
    "    private var swipeGesture: some Gesture {\n"
    "        DragGesture(minimumDistance: SwipeReply.minimumDistance, coordinateSpace: .global)\n"
    "    }\n"
    "    func body(content: Content) -> some View {\n"
    "        content\n"
    "            .simultaneousGesture(swipeGesture, including: actions.isOwnFailed ? .subviews : .all)\n"
    "            .onLongPressGesture(minimumDuration: 0.35) { open() }\n"
    "    }\n"
    "}\n"
    "#endif\n"
)
FIXED_BUBBLE = (
    "#if os(iOS)\n"
    "private struct TouchMessageActions: ViewModifier {\n"
    "    private var swipeGesture: ScrollSafePan {\n"
    "        ScrollSafePan { start, velocity in SwipeReply.begins(startX: start.x, velocity: velocity) } update: { _ in }\n"
    "    }\n"
    "    func body(content: Content) -> some View {\n"
    "        content\n"
    "            .gesture(swipeGesture)\n"
    "            .onLongPressGesture(minimumDuration: 0.35) { open() }\n"
    "    }\n"
    "}\n"
    "#endif\n"
)


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for name, text in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_the_main_6d1891d4_bubble_swipe_fails_and_names_the_helper(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ChatMessageActions.swift": MAIN_6D1891D4_BUBBLE})
    found = csg.scan(root)
    assert [entry.split(": ")[0] for entry in found] == [
        "App/Chat/ChatMessageActions.swift:4",
        "App/Chat/ChatMessageActions.swift:8",
    ]
    assert all("ScrollSafePan" in entry for entry in found)


def test_the_fixed_bubble_passes(tmp_path):
    root = _tree(tmp_path, {"App/Chat/ChatMessageActions.swift": FIXED_BUBBLE})
    assert csg.scan(root) == []


def test_high_priority_gesture_in_a_design_component_fails(tmp_path):
    root = _tree(tmp_path, {"Packages/PalDesign/Sources/PalDesign/Row.swift": "row.highPriorityGesture(tap)\n"})
    assert len(csg.scan(root)) == 1


def test_mac_only_drags_and_justified_surfaces_pass(tmp_path):
    root = _tree(tmp_path, {
        "App/Mac/MacPane.swift": "#if os(macOS)\nrow.simultaneousGesture(DragGesture())\n#endif\n",
        "App/Row.swift": "#if os(iOS)\n.gesture(pan)\n#else\n.simultaneousGesture(drag)\n#endif\n",
        "App/Sheet.swift": "DragGesture(minimumDistance: 8) // scroll-gesture: ok modal sheet\n",
    })
    assert csg.scan(root) == []


def test_the_repository_passes():
    result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout
