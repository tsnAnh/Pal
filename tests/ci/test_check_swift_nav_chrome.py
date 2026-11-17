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
    'Button(action: back) { // nav-chrome: ok\n    Image(systemName: "xmark")\n}\n.accessibilityLabel(Text("Close"))\n',
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
