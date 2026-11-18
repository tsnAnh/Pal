"""scripts/ci/check_swift_nav_chrome.py: Pal screens use the system back and close controls."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_nav_chrome.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_nav_chrome as cnc


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


PRE_FIX_KANBAN_HEADER = '''
            if let back {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\\(identifier)-back")
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                .accessibilityIdentifier("kanban-close")
            }
'''


@pytest.mark.parametrize("body", [
    PRE_FIX_KANBAN_HEADER,
    'Button { dismiss() } label: { Image(systemName: "chevron.left") }\n    .accessibilityLabel(Text("Back"))\n',
    'Button(action: close) {\n    Image(systemName: "xmark")\n}\n.accessibilityIdentifier("sheetClose")\n',
])
def test_custom_back_or_close_fails(tmp_path: Path, body: str) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/View.swift": body}))
    assert found and all(f.startswith("App/View.swift:") for f in found)
    if body is PRE_FIX_KANBAN_HEADER:
        assert len(found) == 2


@pytest.mark.parametrize("body", [
    'ToolbarItem(placement: .cancellationAction) {\n    Button(role: .close, action: close)\n        .accessibilityIdentifier("kanbanBoards-close")\n}\n',
    'Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }\n    .accessibilityLabel(Text("Clear search"))\n',
    'Button(action: remove) {\n    Image(systemName: "xmark")\n}\n.accessibilityLabel(Text("Remove attachment"))\n',
    'Label("Back", systemImage: "chevron.left")\n.accessibilityIdentifier("back")\n',
])
def test_system_controls_and_in_content_glyphs_pass(tmp_path: Path, body: str) -> None:
    assert cnc.scan(_tree(tmp_path, {"App/View.swift": body})) == []


def test_test_targets_are_exempt(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"UITests/U.swift": PRE_FIX_KANBAN_HEADER})
    assert cnc.scan(root) == []


def test_planted_example_fails_the_cli(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"App/Planted.swift": PRE_FIX_KANBAN_HEADER})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Planted.swift:5" in proc.stdout
    assert "ToolbarItem" in proc.stdout


def test_real_apps_ios_tree_is_clean() -> None:
    assert cnc.scan(REPO / "apps" / "ios") == []


PRE_FIX_MAC_TOOLBAR = '''
    var body: some View {
        #if os(macOS)
        scrolling
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close, action: close)
                }
            }
        #else
        SheetChrome(title: title, onLeading: close) { scrolling }
        #endif
    }
'''

PRE_FIX_MAC_OVERLAY = '''
        ZStack {
            KanbanSurface(close: close)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PalTokens.content)
        }
        .ignoresSafeArea(.container, edges: .top)
'''


def test_mac_window_toolbar_item_fails(tmp_path: Path) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/Kanban/Page.swift": PRE_FIX_MAC_TOOLBAR}))
    assert [f.split(": ", 1)[0] for f in found] == ["App/Kanban/Page.swift:5", "App/Kanban/Page.swift:7"]


def test_ios_toolbar_and_in_content_mac_header_pass(tmp_path: Path) -> None:
    ios_only = PRE_FIX_MAC_TOOLBAR.replace("#if os(macOS)", "#if os(iOS)")
    mac_header = "#if os(macOS)\nSheetChrome(title: title, onLeading: close) { scrolling }\n#endif\n"
    assert cnc.scan(_tree(tmp_path, {"App/A.swift": ios_only, "App/B.swift": mac_header})) == []


def test_mac_dir_file_counts_as_macos(tmp_path: Path) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/Mac/Pane.swift": "Text(t).navigationTitle(t)\n"}))
    assert len(found) == 1


def test_full_window_overlay_without_title_bar_inset_fails(tmp_path: Path) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/Mac/Modals.swift": PRE_FIX_MAC_OVERLAY}))
    assert [f.split(": ", 1)[1] for f in found] == ["full-window overlay without the MacMetrics.topBarHeight inset"]


def test_full_window_overlay_with_title_bar_inset_passes(tmp_path: Path) -> None:
    fixed = PRE_FIX_MAC_OVERLAY.replace(
        ".background(PalTokens.content)", ".padding(.top, MacMetrics.topBarHeight)\n                .background(PalTokens.content)"
    )
    assert cnc.scan(_tree(tmp_path, {"App/Mac/Modals.swift": fixed})) == []


PRE_FIX_MAC_PANEL = '''
            .overlayPreferenceValue(MacPanelCloseIdentifierKey.self, alignment: .topTrailing) { override in
                MacPlainCloseButton(identifier: override ?? closeIdentifier, action: close)
            }
'''
FIXED_MAC_PANEL = '''
            .overlayPreferenceValue(MacPanelCloseIdentifierKey.self, alignment: .topLeading) { override in
                SheetGlassButton(accessibilityIdentifier: override ?? closeIdentifier, action: close)
            }
'''
PRE_FIX_PLAIN_CLOSE = '''
        Button(action: action) { // nav-chrome: ok
            Image(systemName: "xmark")
        }
        .accessibilityLabel(Text("Close"))
'''
SEARCH_FIELD = '''
struct ConnectAppsSearchField: View {
    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)%s
    }
}

struct ConnectAppsList: View {
    var body: some View { Text("x") }
}
'''


def test_mac_panel_close_on_the_trailing_side_with_a_plain_button_fails(tmp_path: Path) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/Mac/MacModalSupport.swift": PRE_FIX_MAC_PANEL}))
    assert [f.split(": ", 1)[1] for f in found] == ["Mac panel close must be SheetGlassButton at .topLeading, not .topTrailing"]


def test_mac_panel_close_as_the_shared_leading_glass_button_passes(tmp_path: Path) -> None:
    assert cnc.scan(_tree(tmp_path, {"App/Mac/MacModalSupport.swift": FIXED_MAC_PANEL})) == []


def test_an_opt_out_cannot_waive_a_hand_drawn_close(tmp_path: Path) -> None:
    found = cnc.scan(_tree(tmp_path, {"App/Mac/MacControls.swift": PRE_FIX_PLAIN_CLOSE}))
    assert len(found) == 1 and "cannot waive" in found[0]


def test_sheet_chrome_without_the_shared_bottom_inset_fails(tmp_path: Path) -> None:
    body = "content\n"
    found = cnc.scan(_tree(tmp_path, {"Packages/PalDesign/Sources/PalDesign/Components/SheetChrome.swift": body}))
    assert len(found) == 1 and "sheetBottomInset" in found[0]
    ok = cnc.scan(_tree(tmp_path, {"Packages/PalDesign/Sources/PalDesign/Components/SheetChrome.swift": "content.safeAreaPadding(.bottom, PalMetrics.sheetBottomInset)\n"}))
    assert ok == []


@pytest.mark.parametrize("modifier", [".background(Color.red)", ".palGlass(Capsule())", ".overlay(Capsule())"])
def test_a_styled_connect_apps_search_field_fails(tmp_path: Path, modifier: str) -> None:
    source = SEARCH_FIELD % f"\n            {modifier}"
    found = cnc.scan(_tree(tmp_path, {"App/ConnectApps/ConnectAppsList.swift": source}))
    assert len(found) == 1 and "plain system field" in found[0]


def test_the_plain_connect_apps_search_field_passes(tmp_path: Path) -> None:
    assert cnc.scan(_tree(tmp_path, {"App/ConnectApps/ConnectAppsList.swift": SEARCH_FIELD % ""})) == []


def test_the_floating_search_bar_in_the_connect_apps_list_fails(tmp_path: Path) -> None:
    source = SEARCH_FIELD % "" + "\nFloatingSearchBar(text: $q)\n"
    found = cnc.scan(_tree(tmp_path, {"App/ConnectApps/ConnectAppsList.swift": source}))
    assert len(found) == 1


def test_an_opt_out_still_waives_the_allowlisted_in_content_dismisses(tmp_path: Path) -> None:
    body = 'Button(action: back) { // nav-chrome: ok\n    Image(systemName: "xmark")\n}\n.accessibilityLabel(Text("Close"))\n'
    assert cnc.scan(_tree(tmp_path, {"App/Chat/VoiceModeView.swift": body})) == []
