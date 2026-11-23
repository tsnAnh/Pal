"""scripts/ci/check_swift_esc_dismiss.py: every Mac popup closes with ESC through the shared mechanism."""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_esc_dismiss.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_esc_dismiss as ced

COMPONENTS = "Packages/PalDesign/Sources/PalDesign/Components/"
LAYERS = {
    "App/Mac/MacModalSupport.swift": "MacModalPanel { }\n.palEscape(.sheet) { }\n",
    "App/Mac/MacDialogLayer.swift": ".palEscape(.dialog) { }\n",
    "App/Mac/MacSheetLayer.swift": "MacModalPanel(size: .form, layer: .sheet) { }\n",
    COMPONENTS + "EscapeStack.swift": "Button(\"Close\") {}.keyboardShortcut(.cancelAction)\n",
}
BARE_SHEET = "struct A: View {\n    var body: some View {\n        Text(\"a\").sheet(item: $x) { item in\n            Body(item)\n        }\n    }\n}\n"


def tree(tmp_path: Path, files: dict[str, str] | None = None, layers: dict[str, str] | None = None) -> Path:
    for rel, text in {**(layers or LAYERS), **(files or {})}.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def allowlist(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "allowlist.txt"
    path.write_text(text, encoding="utf-8")
    return path


def rules(found: list[str]) -> list[str]:
    return [entry.split(": ")[1] for entry in found]


def test_bare_sheet_fails_naming_the_fix(tmp_path):
    found = ced.scan(tree(tmp_path, {"App/A.swift": BARE_SHEET}), allowlist(tmp_path, ""))
    assert rules(found) == ["esc-presentation"]
    assert found[0].startswith("App/A.swift:3:")
    assert ".palEscape(" in found[0]
    assert "esc_dismiss_allowlist.txt" in found[0]


def test_sheet_with_palescape_passes(tmp_path):
    source = BARE_SHEET.replace("Body(item)", "Body(item).palEscape(.sheet) { x = nil }")
    assert ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, "")) == []


def test_sheet_with_sheet_chrome_passes(tmp_path):
    source = BARE_SHEET.replace("Body(item)", "SheetChrome(title: \"a\") { }")
    assert ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, "")) == []


def test_comment_and_string_mentions_are_ignored(tmp_path):
    source = '// .sheet(item: $x)\nlet note = ".alert(" /* .popover( */\n'
    assert ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, "")) == []


def test_share_presenter_alert_is_not_a_popup(tmp_path):
    source = 'SharePresenter.alert(title: "a", message: "b")\n'
    assert ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, "")) == []


def test_allowlisted_entry_passes(tmp_path):
    root = tree(tmp_path, {"App/A.swift": BARE_SHEET})
    assert ced.scan(root, allowlist(tmp_path, "App/A.swift:.sheet(  iOS system sheet\n")) == []


def test_stale_entry_fails(tmp_path):
    root = tree(tmp_path, {"App/A.swift": "struct A {}\n"})
    found = ced.scan(root, allowlist(tmp_path, "App/A.swift:.sheet(  gone\nApp/Missing.swift:.sheet(  gone\n"))
    assert rules(found) == ["esc-allowlist-stale", "esc-allowlist-stale"]


def test_entry_without_reason_fails(tmp_path):
    root = tree(tmp_path, {"App/A.swift": BARE_SHEET})
    found = ced.scan(root, allowlist(tmp_path, "App/A.swift:.sheet(  \n"))
    assert "esc-allowlist-reason" in rules(found)
    assert "esc-presentation" in rules(found)


def test_new_cancel_shortcut_outside_shared_files_fails(tmp_path):
    source = 'Button("Cancel") {}\n    .keyboardShortcut(.cancelAction)\n'
    found = ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, ""))
    assert rules(found) == ["esc-copy"]
    assert "palEscape" in found[0]


def test_key_press_escape_and_exit_command_fail(tmp_path):
    source = "v.onKeyPress(.escape) { .handled }\nv.onExitCommand { }\n"
    found = ced.scan(tree(tmp_path, {"App/A.swift": source}), allowlist(tmp_path, ""))
    assert rules(found) == ["esc-copy", "esc-copy"]


def test_shared_files_may_hold_handlers(tmp_path):
    files = {COMPONENTS + "SheetChrome.swift": ".keyboardShortcut(.cancelAction)\n.sheet(item: $x) { }\n"}
    assert ced.scan(tree(tmp_path, files), allowlist(tmp_path, "")) == []


def test_removed_layer_hook_fails(tmp_path):
    layers = {**LAYERS, "App/Mac/MacModalSupport.swift": "MacModalPanel { }\n"}
    found = ced.scan(tree(tmp_path, layers=layers), allowlist(tmp_path, ""))
    assert rules(found) == ["esc-layer-missing"]
    assert found[0].startswith("App/Mac/MacModalSupport.swift:")


def test_real_tree_is_clean():
    assert ced.scan(REPO / "apps" / "ios") == []
