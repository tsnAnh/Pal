"""scripts/ci/check_swift_glass_input.py: every text input is one Liquid Glass surface, never a second field."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_glass_input.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_glass_input as gi

SCREEN = "App/Mac/MacSkills.swift"
COMPONENT = "Packages/PalDesign/Sources/PalDesign/Components/PalTextInput.swift"
NO_ALLOWLIST = Path("/nonexistent/glass_input_allowlist.txt")

CASES = [
    ("glass-input-bordered-style", "TextField(\"a\", text: $t)\n    .textFieldStyle(.roundedBorder)\n",
     "PalTextField(\"a\", text: $t)\n"),
    ("glass-input-bordered-style", "x.textFieldStyle(.squareBorder)\n", "x.textFieldStyle(.plain)\n"),
    ("glass-input-bordered-style", "x.textFieldStyle( .bordered )\n", "x.buttonStyle(.bordered)\n"),
    ("glass-input-bare", "TextField(\"Name\", text: $name)\n", "PalTextField(\"Name\", text: $name)\n"),
    ("glass-input-bare", "SecureField(\"Key\", text: $key)\n", "PalTextField(\"Key\", text: $key, isSecure: true)\n"),
    ("glass-input-bare", "TextEditor(text: $body)\n", "PalTextEditor(text: $body)\n"),
    ("glass-input-bare", "HStack { TextField(\"q\", text: $q) }\n", "ClearGlassSearchField(text: $q)\n"),
    ("glass-input-appkit", "let f = NSTextField(frame: .zero)\n", "let f = NSTextField(labelWithString: \"Title\")\n"),
    ("glass-input-appkit", "let f = NSSearchField()\n", "let f = PalTextField(\"q\", text: $q)\n"),
    ("glass-input-appkit", "let f = NSSecureTextField(string: \"\")\n", "var field: NSTextField?\n"),
    ("glass-input-appkit", "let f = UITextField()\n", "let v = UITextView()\n"),
    ("glass-input-appkit", "final class Field: NSTextField {\n}\n", "final class Viewer: NSTextView {\n}\n"),
    ("glass-input-chrome", "PalTextField(\"a\", text: $t)\n    .background(RoundedRectangle(cornerRadius: 8))\n",
     "PalTextField(\"a\", text: $t)\n    .padding(8)\n    .onSubmit(go)\n"),
    ("glass-input-chrome", "PalTextField(\"a\", text: $t)\n    .overlay(Capsule().stroke(Color.gray))\n",
     "PalTextField(\"a\", text: $t)\n    .overlay(alignment: .trailing) { Spinner() }\n"),
    ("glass-input-chrome", "PalTextEditor(text: $t)\n    .background(PalTokens.control, in: .rect(cornerRadius: 12))\n",
     "PalTextEditor(text: $t)\n    .background(PalTokens.control)\n"),
    ("glass-input-chrome", "SecretField(\"k\", text: $t)\n    .padding(12)\n    .background(\n        Color.clear\n    )\n"
     "    .overlay {\n        Circle().strokeBorder(Color.gray)\n    }\n", "SecretField(\"k\", text: $t)\n    .padding(12)\n"),
    ("glass-input-chrome", "PalTextField(\n    \"\",\n    text: $t\n)\n.font(.body)\n.background(Color.gray, in: .capsule)\n",
     "PalTextField(\n    \"\",\n    text: $t\n)\n.font(.body)\n"),
]


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, body: str, rel: str = SCREEN, allowlist: Path = NO_ALLOWLIST) -> list[str]:
    return [f.rule for f in gi.scan(_tree(tmp_path, {rel: body}), allowlist)]


def _allowlist(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "glass_input_allowlist.txt"
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize(("rule", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", bad)
    assert _rules(tmp_path / "green", good) == []


def test_every_rule_has_a_fixture() -> None:
    assert {rule for rule, _, _ in CASES} == {
        "glass-input-bordered-style", "glass-input-bare", "glass-input-appkit", "glass-input-chrome"
    }


def test_button_bordered_styles_are_not_text_field_styles(tmp_path: Path) -> None:
    assert _rules(tmp_path, "Button(\"Go\") {}\n    .buttonStyle(.bordered)\n    .buttonStyle(.borderedProminent)\n") == []


def test_comments_and_strings_are_not_findings(tmp_path: Path) -> None:
    body = (
        "// TextField(\"a\", text: $t).textFieldStyle(.roundedBorder)\n"
        "/* NSTextField() and SecureField( */\n"
        "let doc = \"TextField( .textFieldStyle(.bordered) UITextField(\"\n"
    )
    assert _rules(tmp_path, body) == []


def test_the_component_file_is_skipped_and_other_dirs_are_scanned(tmp_path: Path) -> None:
    body = "TextField(text: $t)\n    .textFieldStyle(.plain)\n"
    assert _rules(tmp_path / "component", body, COMPONENT) == []
    assert "glass-input-bare" in _rules(tmp_path / "sibling", body, "Packages/PalDesign/Sources/PalDesign/Components/Other.swift")


@pytest.mark.parametrize("rel", ["App/Tests/A.swift", "Tests/A.swift", "UITests/A.swift", "App/Fixtures/A.swift", ".build/A.swift"])
def test_test_and_build_dirs_are_skipped(tmp_path: Path, rel: str) -> None:
    assert _rules(tmp_path, "TextField(\"a\", text: $t)\n", rel) == []


def test_chain_ends_at_the_statement(tmp_path: Path) -> None:
    body = (
        "PalTextField(\"a\", text: $t)\n"
        "Text(\"x\")\n"
        "    .background(RoundedRectangle(cornerRadius: 8))\n"
        "PalTextField(\"b\", text: $u)\n    .padding(4)\n"
        "HStack { PalTextField(\"c\", text: $v) }\n    .background(Capsule())\n"
    )
    assert _rules(tmp_path, body) == []


def test_findings_carry_file_line_rule_and_the_component(tmp_path: Path) -> None:
    body = "import SwiftUI\n\nTextField(\"a\", text: $t)\n    .textFieldStyle(.roundedBorder)\nPalTextField(\"b\", text: $u)\n    .overlay(Capsule())\n"
    found = {(f.path, f.line, f.rule) for f in gi.scan(_tree(tmp_path, {SCREEN: body}), NO_ALLOWLIST)}
    assert found == {
        (SCREEN, 3, "glass-input-bare"),
        (SCREEN, 4, "glass-input-bordered-style"),
        (SCREEN, 5, "glass-input-chrome"),
    }
    assert all("PalTextField" in f.message for f in gi.scan(tmp_path, NO_ALLOWLIST))


def test_allowlist_waives_a_matching_line_only(tmp_path: Path) -> None:
    body = "TextField(\"Name\", text: $name)\nTextField(\"Other\", text: $other)\n"
    root = _tree(tmp_path / "tree", {SCREEN: body})
    allow = _allowlist(tmp_path, f"# format\n\n{SCREEN}:TextField(\"Name\"  the one card with its own surface\n")
    found = gi.scan(root, allow)
    assert [(f.rule, f.line) for f in found] == [("glass-input-bare", 2)]


def test_allowlist_needs_the_same_path(tmp_path: Path) -> None:
    root = _tree(tmp_path / "tree", {SCREEN: "TextField(\"Name\", text: $n)\n", "App/Mac/Other.swift": "let a = 1\n"})
    allow = _allowlist(tmp_path, "App/Mac/Other.swift:TextField(\"Name\"  wrong file\n")
    rules = sorted(f.rule for f in gi.scan(root, allow))
    assert rules == ["glass-input-allowlist", "glass-input-bare"]


def test_stale_allowlist_entry_fails(tmp_path: Path) -> None:
    root = _tree(tmp_path / "tree", {SCREEN: "PalTextField(\"Name\", text: $n)\n"})
    allow = _allowlist(tmp_path, f"{SCREEN}:TextField(\"Name\"  was an own-surface card\n")
    found = gi.scan(root, allow)
    assert [f.rule for f in found] == ["glass-input-allowlist"]
    assert found[0].line == 1
    assert "stale" in found[0].message


def test_allowlist_entry_for_an_absent_file_is_not_stale(tmp_path: Path) -> None:
    root = _tree(tmp_path / "tree", {SCREEN: "let a = 1\n"})
    allow = _allowlist(tmp_path, "App/Mac/Gone.swift:TextField(  deleted file\n")
    assert gi.scan(root, allow) == []


def test_malformed_allowlist_entry_is_a_finding(tmp_path: Path) -> None:
    root = _tree(tmp_path / "tree", {SCREEN: "let a = 1\n"})
    allow = _allowlist(tmp_path, f"{SCREEN}:TextField(\n")
    assert [f.rule for f in gi.scan(root, allow)] == ["glass-input-allowlist"]


def test_repository_allowlist_entries_are_well_formed() -> None:
    waivers, problems = gi.load_allowlist(gi.ALLOWLIST)
    assert problems == []
    assert all(w.reason and w.pattern and not Path(w.path).is_absolute() for w in waivers)


def test_planted_violation_is_reported_with_the_migration_target(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: "import SwiftUI\n\nTextField(\"Search skills\", text: $q)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root), str(NO_ALLOWLIST)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert f"{SCREEN}:3: [glass-input-bare]" in proc.stdout
    assert "PalTextField" in proc.stdout
    assert "PalTextInput.swift" in proc.stdout


def test_clean_tree_exits_zero(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: "PalTextField(\"Search skills\", text: $q)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root), str(NO_ALLOWLIST)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0
    assert proc.stdout == ""
