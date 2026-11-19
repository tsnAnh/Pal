"""scripts/ci/check_swift_icon_tint.py: every Pal icon is drawn through the shared PalDesign component."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_icon_tint.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_icon_tint as csi

SCREEN = "App/View.swift"
DESIGN = "Packages/PalDesign/Sources/PalDesign/Components/Row.swift"


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, rel: str, body: str, allowlist: str = "") -> list[str]:
    root = _tree(tmp_path, {rel: body})
    listing = tmp_path / "allowlist.txt"
    listing.write_text(allowlist, encoding="utf-8")
    return [f.rule for f in csi.scan(root, listing)]


CASES = [
    ("icon-raw-image", SCREEN, "Button { go() } label: {\n    Image(systemName: \"chevron.right\")\n}\n",
     "Button { go() } label: {\n    PalIcon(\"chevron.right\")\n}\n"),
    ("icon-raw-image", DESIGN, "Image(systemName: \"xmark\").font(.caption)\n", "PalIcon(\"xmark\", ink: .secondary).font(.caption)\n"),
    ("icon-raw-label", SCREEN, "ToolbarItem {\n    ShareLink(item: u) { Label(\"Share\", systemImage: \"square.and.arrow.up\") }\n}\n",
     "ToolbarItem {\n    ShareLink(item: u) { Label(\"Share\", palIcon: \"square.and.arrow.up\") }\n}\n"),
    ("icon-raw-label", SCREEN, "Button(\"Save as…\", systemImage: \"square.and.arrow.down\") { save() }\n",
     "Button { save() } label: { Label(\"Save as…\", palIcon: \"square.and.arrow.down\") }\n"),
    ("icon-raw-label", SCREEN, "Menu(\"More\", systemImage: \"ellipsis\") { items }\n",
     "Menu { items } label: { Label(\"More\", palIcon: \"ellipsis\") }\n"),
    ("icon-blue", SCREEN, "ring.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)\n",
     "ring.strokeBorder(PalTokens.textPrimary.opacity(0.9), lineWidth: 2)\n"),
    ("icon-blue", SCREEN, "PalIcon(\"x\").foregroundColor(.blue)\n", "PalIcon(\"x\")\n"),
    ("icon-blue", SCREEN, "Button {} label: { PalIcon(\"x\") }.tint(.blue)\n", "Button {} label: { PalIcon(\"x\") }.tint(.primary)\n"),
    ("icon-blue", SCREEN, "PalIcon(\"x\").foregroundStyle(.tint)\n", "PalIcon(\"x\").foregroundStyle(.secondary)\n"),
    ("icon-blue", SCREEN, "let c = Color.blue\n", "let c = PalTokens.textPrimary\n"),
    ("icon-blue", SCREEN, "view.accentColor(.red)\nlet c = x.accentColor\n", "let c = PalTokens.textPrimary\n"),
    ("icon-symbol-mode", SCREEN, "PalIcon(\"x\").symbolRenderingMode(.multicolor)\n", "PalIcon(\"x\").symbolRenderingMode(.monochrome)\n"),
    ("icon-symbol-mode", SCREEN, "PalIcon(\"x\")\n    .symbolRenderingMode(.palette)\n", "PalIcon(\"x\")\n    .symbolRenderingMode(.hierarchical)\n"),
    ("icon-custom-ink", SCREEN, "PalIcon(\"x\", ink: .custom(bot.accent))\n", "PalIcon(\"x\", ink: .success)\n"),
    ("icon-custom-ink", SCREEN, "PalIcon(\"x\", ink: ticked ? .custom(on) : .tertiary)\n", "PalIcon(\"x\", ink: ticked ? .primary : .tertiary)\n"),
]


@pytest.mark.parametrize(("rule", "rel", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, rel: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", rel, bad)
    assert _rules(tmp_path / "green", rel, good) == []


def test_every_rule_has_a_fixture() -> None:
    assert {rule for rule, _, _ in csi.RULES} == {rule for rule, *_ in CASES}


def test_component_file_is_the_one_place_that_draws_the_raw_image(tmp_path: Path) -> None:
    body = "Image(systemName: name).foregroundStyle(color)\n"
    assert _rules(tmp_path / "a", str(csi.COMPONENT), body) == []
    assert _rules(tmp_path / "b", SCREEN, body) == ["icon-raw-image"]


def test_comments_strings_tests_and_text_interpolation_are_not_findings(tmp_path: Path) -> None:
    body = (
        "// Image(systemName: \"x\") and .accentColor\n"
        "let doc = \"Label(systemImage: x)\"\n"
        "let line = Text(\"Tap \\(Image(systemName: \"plus\")) to add\")\n"
        "let globe = Text(Image(systemName: \"globe\")).foregroundStyle(ink)\n"
    )
    assert _rules(tmp_path / "a", SCREEN, body) == []
    assert _rules(tmp_path / "b", "UITests/View.swift", "Image(systemName: \"x\")\n") == []
    assert _rules(tmp_path / "c", "Packages/PalDesign/Tests/PalDesignTests/T.swift", "Image(systemName: \"x\")\n") == []


def test_allowlist_covers_one_rule_in_one_file_and_needs_a_reason(tmp_path: Path) -> None:
    body = "Image(systemName: \"x\")\nlet c = Color.blue\n"
    assert _rules(tmp_path / "a", SCREEN, body, f"{SCREEN}:icon-raw-image: avatar glyph, artwork\n") == ["icon-blue"]
    assert _rules(tmp_path / "b", SCREEN, body, f"{SCREEN}:icon-raw-image:\n") == ["icon-allowlist", "icon-raw-image", "icon-blue"]
    assert _rules(tmp_path / "c", SCREEN, body, f"{SCREEN}:icon-nope: why\n") == ["icon-allowlist", "icon-raw-image", "icon-blue"]


def test_stale_allowlist_entry_fails(tmp_path: Path) -> None:
    assert _rules(tmp_path, SCREEN, "PalIcon(\"x\")\n", f"{SCREEN}:icon-raw-image: avatar glyph\n") == ["icon-allowlist"]


def test_repository_allowlist_has_a_reason_per_entry() -> None:
    allowed, problems = csi.load_allowlist(csi.ALLOWLIST)
    assert problems == [] and all(reason for reason in allowed.values())


def test_repository_passes() -> None:
    assert csi.scan(REPO / "apps" / "ios") == []


def test_planted_violation_is_reported_with_file_line_rule_and_the_component(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"App/Planted.swift": "import SwiftUI\n\nlet bad = Image(systemName: \"chevron.right\")\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Planted.swift:3: [icon-raw-image]" in proc.stdout
    assert "PalIcon" in proc.stdout
