"""scripts/ci/check_swift_mac_layout.py: the Mac shell fits its window and sidebar rows fit their column."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_mac_layout.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_mac_layout as cml

METRICS = (
    "public enum MacLayoutMetrics {\n"
    "    public static let sidebarWidthRange: ClosedRange<CGFloat> = 240...400\n"
    "    public static let chatColumnMin: CGFloat = 500\n"
    "    public static let windowMin: CGFloat = sidebarWidthRange.upperBound + chatColumnMin\n"
    "}\n"
)
SHELL = (
    "struct MacShellView: View {\n"
    "    var shellContent: some View {\n"
    "        MacShellLayout { sidebar; detail }\n"
    "    }\n"
    "}\n"
    "enum MacMetrics {\n"
    "    static let topBarHeight: CGFloat = 55\n"
    "}\n"
)
SIDEBAR = (
    "struct MacSidebar: View {\n"
    "    var expanded: some View {\n"
    "        ScrollView {\n"
    "            LazyVStack(spacing: 3) {\n"
    "                MacBotRow()\n"
    "            }\n"
    "            .boundedToColumn()\n"
    "        }\n"
    "    }\n"
    "}\n"
    "private struct MacBotRow: View {\n"
    "    var body: some View {\n"
    "        Button {} label: { Text(\"x\") }\n"
    "            .buttonStyle(.plain)\n"
    "            .boundedToColumn()\n"
    "    }\n"
    "}\n"
)
APP = "struct PalApp {\n    var body: some Scene {\n        WindowGroup {}.defaultSize(width: MacLayoutMetrics.defaultWindowWidth, height: 1)\n    }\n}\n"


def _tree(tmp_path: Path, overrides: dict[str, str] | None = None) -> Path:
    files = {
        "Packages/PalDesign/Sources/PalDesign/Theme/MacLayoutMetrics.swift": METRICS,
        "App/Mac/MacShell.swift": SHELL,
        "App/Mac/MacSidebar.swift": SIDEBAR,
        "App/PalApp.swift": APP,
    }
    files.update(overrides or {})
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_a_bounded_shell_passes(tmp_path):
    assert cml.scan(_tree(tmp_path)) == []


def test_a_window_literal_in_the_app_fails_on_the_real_pal_app_line(tmp_path):
    root = _tree(tmp_path, {"App/PalApp.swift": APP.replace("MacLayoutMetrics.defaultWindowWidth", "1280")})
    found = cml.scan(root)
    assert len(found) == 1 and found[0].startswith("App/PalApp.swift:3:") and "MacLayoutMetrics" in found[0]


def test_sidebar_and_chat_widths_declared_outside_the_metrics_fail(tmp_path):
    shell = SHELL.replace("    static let topBarHeight", "    static let sidebarWidth: CGFloat = 280\n    static let inspectorWidth: CGFloat = 320\n    static let chatColumn: CGFloat = 882\n    static let topBarHeight")
    found = cml.scan(_tree(tmp_path, {"App/Mac/MacShell.swift": shell}))
    assert [entry.split(":")[1] for entry in found] == ["7", "8", "9"]


def test_a_window_minimum_that_ignores_the_sidebar_fails(tmp_path):
    metrics = METRICS.replace("sidebarWidthRange.upperBound + chatColumnMin", "chatColumnMin")
    found = cml.scan(_tree(tmp_path, {"Packages/PalDesign/Sources/PalDesign/Theme/MacLayoutMetrics.swift": metrics}))
    assert len(found) == 1 and "mac-window-min" in found[0]


def test_laying_the_shell_out_with_a_stack_fails(tmp_path):
    shell = SHELL.replace("MacShellLayout { sidebar; detail }", "HStack(spacing: 0) { sidebar; detail }")
    found = cml.scan(_tree(tmp_path, {"App/Mac/MacShell.swift": shell}))
    assert any(":3: mac-shell-stack" in entry for entry in found) and any("does not use MacShellLayout" in entry for entry in found)


def test_an_unbounded_row_stack_and_row_fail(tmp_path):
    sidebar = SIDEBAR.replace("            .boundedToColumn()\n        }\n    }\n}\nprivate", "        }\n    }\n}\nprivate").replace("            .boundedToColumn()\n    }\n}\n", "    }\n}\n")
    found = cml.scan(_tree(tmp_path, {"App/Mac/MacSidebar.swift": sidebar}))
    assert [entry.split(": ")[1] for entry in found] == ["mac-row-unbounded", "mac-row-unbounded"]
    assert found[0].startswith("App/Mac/MacSidebar.swift:4:") and found[1].startswith("App/Mac/MacSidebar.swift:10:")


def test_fixed_size_text_in_a_row_fails(tmp_path):
    sidebar = SIDEBAR.replace('Text("x")', 'Text("x").fixedSize(horizontal: true, vertical: false)')
    found = cml.scan(_tree(tmp_path, {"App/Mac/MacSidebar.swift": sidebar}))
    assert len(found) == 1 and "mac-row-fixed-size" in found[0]


def test_the_opt_out_marker_waives_the_line(tmp_path):
    root = _tree(tmp_path, {"App/PalApp.swift": APP.replace("MacLayoutMetrics.defaultWindowWidth", "1280 // mac-layout: ok fixture")})
    assert cml.scan(root) == []


def test_the_real_tree_is_clean():
    assert cml.scan(REPO / "apps" / "ios") == []
