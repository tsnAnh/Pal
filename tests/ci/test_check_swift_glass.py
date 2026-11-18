"""scripts/ci/check_swift_glass.py: Pal Swift code follows the Liquid Glass design rules."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_glass.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_glass as csg

DESIGN = "Packages/PalDesign/Sources/PalDesign/Components/Part.swift"
SCREEN = "App/View.swift"


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, rel: str, body: str) -> list[str]:
    return [f.rule for f in csg.scan(_tree(tmp_path, {rel: body}))]


PRE_FIX_PAL_GLASS = """
public enum PalGlass {
    static let darkTint = Color.black.opacity(0.4)

    public static func style(_ base: Glass = .regular, interactive: Bool, colorScheme: ColorScheme) -> Glass {
        let tinted = colorScheme == .dark ? base.tint(darkTint) : base
        return interactive ? tinted.interactive() : tinted
    }
}
"""

CASES = [
    ("glass-dark-tint", SCREEN, "Button(\"Go\") {}\n    .buttonStyle(.glass(.regular.tint(Color.black.opacity(0.4))))\n",
     "Button(\"Go\") {}\n    .buttonStyle(.glass)\n    .shadow(color: .black.opacity(0.3), radius: 8)\n"),
    ("glass-dark-tint", SCREEN, "Capsule().glassEffect(.regular.tint(.black))\n", "Capsule().palGlass(Capsule())\n"),
    ("glass-dark-tint", DESIGN, PRE_FIX_PAL_GLASS, "static func style(_ base: Glass) -> Glass { base }\n"),
    ("glass-hand-rolled", SCREEN, "Text(t).glassEffect(.regular, in: Capsule())\n", "Text(t).palGlass(Capsule())\n"),
    ("glass-hand-rolled", SCREEN, "let view = NSGlassEffectView()\n", "let view = NSVisualEffectView()\n"),
    ("glass-pill-button", SCREEN, "Button(\"Go\") {}.buttonStyle(.pill(.accent))\n", "Button(\"Go\") {}.buttonStyle(.glass)\n"),
    ("glass-pill-button", SCREEN, "PillButton(\"Try again\", accessibilityIdentifier: \"retry\") {}\n",
     "Button(\"Try again\") {}.buttonStyle(.glass)\n"),
    ("glass-pill-button", SCREEN, "Button(\"Go\") {}.buttonStyle(.palPill(height: 28))\n", "Button(\"Go\") {}.buttonStyle(.palGlass)\n"),
    ("glass-pill-button", SCREEN, "Button(\"Go\") { go() }\n    .background(Color.blue, in: Capsule())\n",
     "Button(\"Go\") { go() }\n    .buttonStyle(.glassProminent)\n"),
    ("glass-container", SCREEN,
     "var bar: some View {\n    HStack {\n        a.palGlass(Circle())\n        b.palGlass(Circle())\n    }\n}\n",
     "var bar: some View {\n    GlassEffectContainer(spacing: 8) {\n        a.palGlass(Circle())\n        b.palGlass(Circle())\n    }\n}\n"),
    ("glass-sheet-chrome", SCREEN,
     "SheetChrome(title: t, accessibilityIdentifier: \"s\", onLeading: close) {\n    list\n        .padding(.bottom, 32)\n}\n",
     "SheetChrome(title: t, accessibilityIdentifier: \"s\", onLeading: close) {\n    list\n}\n"),
    ("glass-sheet-chrome", SCREEN,
     "ToolbarItem(placement: .topBarTrailing) {\n    Button(\"Close\") { dismiss() }\n}\n",
     "ToolbarItem(placement: .cancellationAction) {\n    Button(role: .close) { dismiss() }\n}\n"),
    ("glass-sheet-chrome", SCREEN, "Button(\"Close\") { dismiss() }\n", "Button(role: .close) { dismiss() }\n"),
    ("glass-sheet-chrome", SCREEN,
     ".sheet(isPresented: $on) {\n    NavigationStack {\n        form.navigationTitle(\"New\")\n    }\n}\n",
     ".sheet(isPresented: $on) {\n    SheetChrome(title: \"New\", accessibilityIdentifier: \"s\", onLeading: close) { form }\n}\n"),
    ("glass-search-field", SCREEN,
     "TextField(\"Search models\", text: $query)\n    .padding(8)\n    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))\n",
     "List(rows) { row }\n    .searchable(text: $query)\n"),
    ("glass-search-field", SCREEN,
     "HStack {\n    Image(systemName: \"magnifyingglass\")\n    TextField(\"Search\", text: $q)\n}\n.padding(8)\n.background(PalTokens.control)\n",
     "TextField(\"Name\", text: $name)\n    .background(PalTokens.control)\n"),
    ("glass-search-field", SCREEN, "struct ProviderSearchField: View {\n    var body: some View { EmptyView() }\n}\n",
     "struct ProviderList: View {\n    var body: some View { EmptyView() }\n}\n"),
    ("glass-floating-bar", SCREEN,
     "var body: some View {\n    ScrollView { rows }\n        .overlay(alignment: .bottom) { bar.padding(.bottom, 12) }\n}\n",
     "var body: some View {\n    ScrollView { rows }\n        .safeAreaInset(edge: .bottom) { bar.background(.bar) }\n}\n"),
    ("glass-floating-bar", SCREEN,
     "var body: some View {\n    list\n        .safeAreaInset(edge: .bottom, spacing: 0) { Button(\"Go\") {} }\n}\n",
     "var body: some View {\n    list\n        .safeAreaInset(edge: .bottom, spacing: 0) { footer }\n}\n"
     "var footer: some View {\n    Button(\"Go\") {}\n        .background(.regularMaterial)\n}\n"),
    ("glass-raw-color", SCREEN, "let tile = Color(red: 0.1, green: 0.2, blue: 0.3)\n", "let tile = PalTokens.control\n"),
    ("glass-raw-color", SCREEN, "let dot = Color(white: 0.4)\n", "let dot = Color.secondary\n"),
    ("glass-raw-color", SCREEN, "let hue = \"#0f7a3c\"\n", "let hue = \"#fragment\"\n"),
]


@pytest.mark.parametrize(("rule", "rel", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, rel: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", rel, bad)
    assert _rules(tmp_path / "green", rel, good) == []


def test_every_rule_has_a_fixture() -> None:
    covered = {rule for rule, *_ in CASES}
    declared = {lr.rule for lr in csg.LINE_RULES} | {rule for rule, _, _ in csg.BLOCK_RULES}
    assert declared == covered


def test_rules_that_belong_to_one_layer_ignore_the_other(tmp_path: Path) -> None:
    assert _rules(tmp_path / "a", DESIGN, "Text(t).glassEffect(.regular, in: Capsule())\n") == []
    assert _rules(tmp_path / "b", DESIGN, "let c = Color(white: 0.4)\n") == []
    assert _rules(tmp_path / "c", DESIGN, "TextField(\"Search\", text: $q).background(.red)\nstruct SearchField: View {}\n") == [
        "glass-search-field"
    ]


def test_opt_out_marker_and_test_targets_are_exempt(tmp_path: Path) -> None:
    marked = "let tile = Color(white: 0.4) // glass-lint: ok\n"
    assert _rules(tmp_path / "a", SCREEN, marked) == []
    assert _rules(tmp_path / "b", "UITests/View.swift", "let tile = Color(white: 0.4)\n") == []


def test_comments_and_strings_do_not_trigger(tmp_path: Path) -> None:
    body = "// Color(white: 0.4) and .tint(.black)\nlet label = \"PillButton(x)\"\n/* .glassEffect( */\n"
    assert _rules(tmp_path, SCREEN, body) == []


def test_baseline_absorbs_known_findings_but_not_new_ones(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: "let a = Color(white: 0.4)\n"})
    found = csg.scan(root)
    csg.write_baseline(root / csg.BASELINE_NAME, found)
    baseline = csg.load_baseline(root / csg.BASELINE_NAME)
    assert csg.new_findings(found, baseline) == ([], 0)
    (root / SCREEN).write_text("\n\nlet a = Color(white: 0.4)\nlet b = Color(white: 0.5)\n", encoding="utf-8")
    fresh, stale = csg.new_findings(csg.scan(root), baseline)
    assert [f.text for f in fresh] == ["let b = Color(white: 0.5)"] and stale == 0
    (root / SCREEN).write_text("let a = PalTokens.control\n", encoding="utf-8")
    assert csg.new_findings(csg.scan(root), baseline) == ([], 1)


def test_planted_violation_is_reported_with_file_line_rule_and_fix(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"App/Planted.swift": "import SwiftUI\n\nlet bad = Capsule().glassEffect(.regular.tint(.black))\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Planted.swift:3: [glass-dark-tint]" in proc.stdout
    assert "App/Planted.swift:3: [glass-hand-rolled]" in proc.stdout
    assert "Use PalGlass" in proc.stdout


def test_real_tree_fails_without_baseline_and_passes_with_it() -> None:
    root = REPO / "apps" / "ios"
    without = csg.scan(root)
    assert any(f.rule == "glass-dark-tint" and f.path.endswith("PalControls.swift") for f in without)
    assert csg.new_findings(without, csg.load_baseline(root / csg.BASELINE_NAME))[0] == []
    entries = json.loads((root / csg.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert all(set(e) == {"rule", "file", "text"} for e in entries)
