"""scripts/ci/check_swift_connect_palette.py: the Connect Apps sheet is clear glass and ink only."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_connect_palette.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_connect_palette as ccp

LIST = "App/ConnectApps/ConnectAppsList.swift"
SCREEN = "App/ConnectApps/ConnectAppsScreen.swift"
BUTTONS = "App/Setup/SetupButtons.swift"
OUTSIDE = "App/Chat/ChatView.swift"
TOKENS = "App/Profile/SlackTokensView.swift"
FIELDS = "App/Setup/StepFlowFields.swift"
PROGRESS = "App/Setup/StepFlowProgressViews.swift"

LIST_CADD1B77 = (
    "TextField(\"Search\", text: $query)\n"
    "            .textFieldStyle(.roundedBorder)\n"
    "Image(systemName: \"x\")\n"
    "                    .foregroundStyle(row.hasProblem ? Color.red : PalTokens.textSecondary)\n"
)
SCREEN_CADD1B77 = "ProgressView()\n                    .tint(.primary)\n"
BUTTONS_CADD1B77 = (
    "        case .primary: Glass.regular.tint(PalTokens.toggleOn).interactive()\n"
    "        case .secondary: Glass.regular.interactive()\n"
)


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, rel: str, body: str, allowlist: dict[tuple[str, str], str] | None = None) -> list[str]:
    root = _tree(tmp_path, {rel: body})
    return [f.rule for f in ccp.scan(root, allowlist or {})]


CASES = [
    ("connect-blue", LIST, "let c = Color.blue\n", "let c = PalTokens.textPrimary\n"),
    ("connect-blue", LIST, "Text(x).foregroundStyle(.blue)\n", "Text(x).foregroundStyle(.primary)\n"),
    ("connect-blue", LIST, "let c = Color(.blue)\n", "let c = Color(.label)\n"),
    ("connect-accent", SCREEN, "Rectangle().fill(Color.accentColor)\n", "Rectangle().fill(PalTokens.textPrimary)\n"),
    ("connect-red", LIST, "view.foregroundStyle(bad ? Color.red : PalTokens.textSecondary)\n",
     "view.foregroundStyle(bad ? Color(theme.palette.destructive) : PalTokens.textSecondary)\n"),
    ("connect-green", TOKENS, "view.strokeBorder(Color.green.opacity(0.5), lineWidth: 1.5)\n",
     "view.strokeBorder(PalTokens.borderStrong, lineWidth: 1.5)\n"),
    ("connect-toggle-blue", PROGRESS, "case .done: PalTokens.toggleOn\n", "case .done: PalTokens.inverseFill\n"),
    ("connect-hex", LIST, "let c = RGB(hex: 0x2d7cf6)\n", "let c = PalTokens.textPrimary\n"),
    ("connect-hex", LIST, "let c = Color(hex: \"#2d7cf6\")\n", "let c = PalTokens.textPrimary\n"),
    ("connect-hex", LIST, "let raw = 0x2d7cf6\n", "let raw = PalTokens.textPrimary\n"),
    ("connect-tint", SCREEN, SCREEN_CADD1B77, "ProgressView()\n"),
    ("connect-bordered-field", LIST, LIST_CADD1B77.split("Image")[0], "ClearGlassSearchField(text: $query)\n"),
    ("connect-glass-regular", BUTTONS, "case .secondary: Glass.regular.interactive()\n", "case .secondary: Glass.clear.interactive()\n"),
]


@pytest.mark.parametrize(("rule", "rel", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, rel: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", rel, bad)
    assert _rules(tmp_path / "green", rel, good) == []


def test_every_rule_has_a_fixture() -> None:
    assert {rule for rule, _, _ in ccp.RULES + ccp.SLACK_RULES} == {rule for rule, *_ in CASES}


def test_the_slack_setup_files_are_scanned_with_every_rule(tmp_path: Path) -> None:
    for rel in (TOKENS, FIELDS, PROGRESS):
        assert "connect-red" in _rules(tmp_path / Path(rel).stem, rel, "let c = Color.red\n")
    assert _rules(tmp_path / "other", "App/Profile/BotProfile.swift", "let c = Color.green\n") == []
    assert _rules(tmp_path / "connect", LIST, "let c = Color.green\n") == []


def test_main_f67f20e8_slack_token_field_lines_are_found(tmp_path: Path) -> None:
    body = (
        "                        .strokeBorder(shape.isValid ? Color.green.opacity(0.5) : (shape == .empty ? Color.clear : Color.red), lineWidth: 1.5)\n"
        "                    .foregroundStyle(shape.isValid ? Color.green : Color.red)\n"
    )
    root = _tree(tmp_path, {TOKENS: body})
    found = {(f.line, f.rule) for f in ccp.scan(root, {})}
    assert found == {(1, "connect-green"), (1, "connect-red"), (2, "connect-green"), (2, "connect-red")}


def test_cadd1b77_lines_are_found_with_their_line_numbers(tmp_path: Path) -> None:
    root = _tree(tmp_path, {LIST: LIST_CADD1B77, SCREEN: SCREEN_CADD1B77, BUTTONS: BUTTONS_CADD1B77})
    found = {(f.path, f.line, f.rule) for f in ccp.scan(root, {})}
    assert found == {
        (LIST, 2, "connect-bordered-field"),
        (LIST, 4, "connect-red"),
        (SCREEN, 2, "connect-tint"),
        (BUTTONS, 1, "connect-tint"),
        (BUTTONS, 1, "connect-glass-regular"),
        (BUTTONS, 2, "connect-glass-regular"),
    }


def test_only_the_connect_apps_sheet_and_setup_buttons_are_scanned(tmp_path: Path) -> None:
    assert _rules(tmp_path / "a", OUTSIDE, "let c = Color.blue\n") == []
    assert _rules(tmp_path / "b", "App/Setup/OtherSetup.swift", "let c = Color.blue\n") == []


def test_comments_and_strings_are_not_findings(tmp_path: Path) -> None:
    body = "// Color.blue and .tint(\nlet doc = \"Glass.regular and 0x2d7cf6\"\n"
    assert _rules(tmp_path, LIST, body) == []


def test_allowlist_covers_one_rule_in_one_file(tmp_path: Path) -> None:
    body = "let a = Color.red\nlet b = Color.blue\n"
    assert _rules(tmp_path, LIST, body, {(LIST, "connect-red"): "status mark"}) == ["connect-blue"]


def test_stale_allowlist_entry_fails(tmp_path: Path) -> None:
    assert _rules(tmp_path, LIST, "let a = 1\n", {(LIST, "connect-red"): "status mark"}) == ["connect-allowlist"]


def test_allowlist_entry_for_an_absent_file_is_not_stale(tmp_path: Path) -> None:
    assert _rules(tmp_path, LIST, "let a = 1\n", {("App/ConnectApps/Gone.swift", "connect-red"): "status mark"}) == []


def test_repository_allowlist_has_a_reason_per_entry() -> None:
    known = {rule for rule, _, _ in ccp.RULES + ccp.SLACK_RULES}
    assert all(reason and rule in known for (_, rule), reason in ccp.ALLOWLIST.items())


def test_planted_violation_is_reported_with_file_line_rule_and_the_token(tmp_path: Path) -> None:
    root = _tree(tmp_path, {LIST: "import SwiftUI\n\nlet bad = Color.red\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert f"{LIST}:3: [connect-red]" in proc.stdout
    assert "theme.palette.destructive" in proc.stdout
