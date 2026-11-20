"""scripts/ci/check_swift_modal_size.py: Mac modals take their size from the shared container and alerts use the shared dialog."""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_modal_size.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_modal_size as cms

PANEL = (
    "struct MacModalPanel<Content: View>: View {\n"
    "    var fit = MacModalFit.window\n"
    "    let identifier: String\n"
    "    @ViewBuilder let content: Content\n"
    "}\n"
)
HOST = (
    "struct MacModalHost: View {\n"
    "    var body: some View {\n"
    '        MacModalPanel(identifier: "a", closeIdentifier: "b", close: {}) {\n'
    "            Settings().frame(width: 20)\n"
    "        }\n"
    "    }\n"
    "}\n"
)
PALETTE = (
    "struct MacPalette: View {\n"
    "    var body: some View {\n"
    "        VStack {\n"
    "            Row().frame(width: 590)\n"
    "        }\n"
    "        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)\n"
    "    }\n"
    "}\n"
)
SCREEN = (
    "struct Screen: View {\n"
    "    var body: some View {\n"
    "        Text(\"x\")\n"
    "            .macConfirm(isPresented: $a) { MacDialogContent(\"t\", actions: []) }\n"
    "    }\n"
    "}\n"
)


def _tree(tmp_path: Path, overrides: dict[str, str] | None = None) -> Path:
    files = {
        "App/Mac/MacModalSupport.swift": PANEL,
        "App/Mac/MacModals.swift": HOST,
        "App/Mac/MacPalette.swift": PALETTE,
        "App/Settings/Screen.swift": SCREEN,
    }
    files.update(overrides or {})
    for name, body in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def test_a_container_sized_tree_passes(tmp_path):
    assert cms.scan(_tree(tmp_path)) == []


def test_a_fixed_panel_size_in_a_call_fails_and_names_the_container(tmp_path):
    host = HOST.replace("MacModalPanel(identifier", "MacModalPanel(width: 824, height: 478, identifier")
    found = cms.scan(_tree(tmp_path, {"App/Mac/MacModals.swift": host}))
    assert len(found) == 1 and found[0].startswith("App/Mac/MacModals.swift:3: modal-panel-size") and "fit: .content" in found[0]


def test_a_frame_inside_the_panel_content_is_not_a_panel_size(tmp_path):
    host = HOST.replace("Settings()", "Settings().frame(width: 480, height: 300)")
    assert cms.scan(_tree(tmp_path, {"App/Mac/MacModals.swift": host})) == []


def test_a_width_or_height_parameter_on_the_panel_type_fails(tmp_path):
    panel = PANEL.replace("    let identifier", "    let width: CGFloat\n    var height: CGFloat?\n    let identifier")
    found = cms.scan(_tree(tmp_path, {"App/Mac/MacModalSupport.swift": panel}))
    assert [entry.split(":")[1] for entry in found] == ["3", "4"]


def test_a_literal_frame_on_a_modal_root_fails(tmp_path):
    palette = PALETTE.replace("        .frame(maxWidth", "        .frame(width: 590)\n        .frame(maxWidth")
    found = cms.scan(_tree(tmp_path, {"App/Mac/MacPalette.swift": palette}))
    assert len(found) == 1 and found[0].startswith("App/Mac/MacPalette.swift:6: modal-root-frame") and "MacModalSizing" in found[0]


def test_system_alert_and_confirmation_dialog_fail_and_name_the_shared_modifiers(tmp_path):
    screen = SCREEN.replace(".macConfirm(isPresented: $a) { MacDialogContent(\"t\", actions: []) }", ".alert(\"t\", isPresented: $a) {}\n            .confirmationDialog(\"t\", isPresented: $b) {}")
    found = cms.scan(_tree(tmp_path, {"App/Settings/Screen.swift": screen}))
    assert [entry.split(":")[1] for entry in found] == ["4", "5"]
    assert all("modal-system-alert" in entry and ".macAlert" in entry and ".macConfirm" in entry for entry in found)


def test_ios_only_code_and_the_dialog_implementation_may_use_system_alerts(tmp_path):
    ios = "#if os(iOS)\nstruct A { var body: some View { Text(\"x\").alert(\"t\", isPresented: $a) {} } }\n#endif\n"
    only = SCREEN.replace(".macConfirm(isPresented: $a) { MacDialogContent(\"t\", actions: []) }", ".iOSOnly { view in\n                view.alert(\"t\", isPresented: $a) {}\n            }")
    fallback = "#if os(macOS)\nlet a = 1\n#else\nstruct B { var body: some View { Text(\"x\").alert(\"t\", isPresented: $a) {} } }\n#endif\n"
    overrides = {
        "App/Settings/Ios.swift": ios,
        "App/Settings/Screen.swift": only,
        "Packages/PalDesign/Sources/PalDesign/Components/MacDialog.swift": "extension View { func f() { alert(\"\") } }\nvar x = Text(\"\").alert(\"t\", isPresented: $a) {}\n",
    }
    overrides["App/Settings/Else.swift"] = fallback
    assert cms.scan(_tree(tmp_path, overrides)) == []


def test_the_else_branch_of_an_ios_condition_is_mac_code(tmp_path):
    mac_else = (
        "#if os(iOS)\n"
        "let a = 1\n"
        "#else\n"
        "struct B { var body: some View { Text(\"x\").alert(\"t\", isPresented: $a) {} } }\n"
        "#endif\n"
    )
    found = cms.scan(_tree(tmp_path, {"App/Settings/Else.swift": mac_else}))
    assert len(found) == 1 and found[0].startswith("App/Settings/Else.swift:4:")


def test_a_macos_branch_is_checked_and_share_presenter_alert_is_not_a_modifier(tmp_path):
    mac = "#if os(macOS)\nstruct A { var body: some View { Text(\"x\").confirmationDialog(\"t\", isPresented: $a) {} } }\n#endif\n"
    share = "func f() { SharePresenter.alert(title: \"a\", message: \"b\") }\n"
    found = cms.scan(_tree(tmp_path, {"App/Settings/Mac.swift": mac, "App/Settings/Share.swift": share}))
    assert len(found) == 1 and found[0].startswith("App/Settings/Mac.swift:2:")


def test_the_opt_out_marker_waives_the_line(tmp_path):
    screen = SCREEN.replace(".macConfirm(isPresented: $a) { MacDialogContent(\"t\", actions: []) }", ".alert(\"t\", isPresented: $a) {} // modal-size: ok fixture")
    assert cms.scan(_tree(tmp_path, {"App/Settings/Screen.swift": screen})) == []


def test_the_real_tree_is_clean():
    assert cms.scan(REPO / "apps" / "ios") == []


def test_an_overlay_after_the_modal_environment_is_a_finding_and_applying_it_last_is_clean(tmp_path: Path) -> None:
    broken = (
        "struct Root: View {\n"
        "    var body: some View {\n"
        "        navigation\n"
        "            .environment(rooms).macModalEnvironment()\n"
        "            .task { await load() }\n"
        "            .overlay {\n"
        "                MacModalHost()\n"
        "            }\n"
        "    }\n"
        "}\n"
    )
    found = cms.scan(_tree(tmp_path, {"App/Root.swift": broken}))
    assert [f for f in found if "modal-env-scope" in f] == [
        "App/Root.swift:4: modal-env-scope: .overlay at line 6 sits outside it; " + cms.FIX_ENV
    ]
    fixed = broken.replace(".environment(rooms).macModalEnvironment()", ".environment(rooms)").replace(
        "            }\n    }", "            }\n            .macModalEnvironment()\n    }"
    )
    assert not [f for f in cms.scan(_tree(tmp_path, {"App/Root.swift": fixed})) if "modal-env-scope" in f]


STATUS_BLOCK = (
    "struct StatusBlock: View {\n"
    "    var body: some View {\n"
    "        VStack { Text(\"x\") }\n"
    "    }\n"
    "}\n"
)


def test_a_window_panel_surface_without_the_scroll_container_fails_and_names_the_fix(tmp_path):
    found = cms.scan(_tree(tmp_path, {"App/Setup/StatusBlock.swift": STATUS_BLOCK}))
    assert found == ["App/Setup/StatusBlock.swift:1: modal-overflow: StatusBlock: " + cms.FIX_OVERFLOW]
    assert "MacOverflowScroll" in found[0]


def test_wrapping_the_surface_in_the_scroll_container_passes(tmp_path):
    wrapped = STATUS_BLOCK.replace("        VStack { Text(\"x\") }\n", "        MacOverflowScroll { VStack { Text(\"x\") } }\n")
    assert cms.scan(_tree(tmp_path, {"App/Setup/StatusBlock.swift": wrapped})) == []


def test_the_scroll_container_in_another_struct_of_the_file_does_not_count(tmp_path):
    other = STATUS_BLOCK + "struct Other: View {\n    var body: some View { MacOverflowScroll { Text(\"y\") } }\n}\n"
    found = cms.scan(_tree(tmp_path, {"App/Setup/StatusBlock.swift": other}))
    assert [f.split(":")[0] for f in found] == ["App/Setup/StatusBlock.swift"]


def test_every_registered_overflow_surface_exists_in_the_real_tree():
    root = REPO / "apps" / "ios"
    for rel, structs in cms.OVERFLOW_SURFACES.items():
        text = (root / rel).read_text(encoding="utf-8")
        for struct in structs:
            assert re.search(rf"\bstruct {struct}\b", text), f"{rel} no longer declares {struct}; update OVERFLOW_SURFACES"
