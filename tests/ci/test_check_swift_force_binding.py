"""scripts/ci/check_swift_force_binding.py: no force-unwrapped Binding, no restored viewer state."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_force_binding.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_force_binding as cfb

HOST = "App/Chat/ImageViewer/MacMediaViewer.swift"
SCREEN = "App/ChatView.swift"


def _rules(tmp_path: Path, rel: str, body: str) -> list[str]:
    path = tmp_path / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return [f.rule for f in cfb.scan(tmp_path)]


@pytest.mark.parametrize("line", [
    "if let state = Binding($viewer) {",
    "if let state = Binding<MediaViewerState>($media) {",
    "Child(item: $model.selected!)",
    "Child(item: $model.parent?.selected!)",
    "Child(item: Binding(unwrapping: $item))",
])
def test_force_unwrapped_bindings_are_flagged(tmp_path: Path, line: str) -> None:
    assert _rules(tmp_path, SCREEN, f"struct V: View {{ var body: some View {{\n{line}\n}} }}\n") == ["binding-force-unwrap"]


@pytest.mark.parametrize("line", [
    "Child(item: $model.selected)",
    "if $0 != nil { }",
    "Binding(get: { viewer ?? last }, set: { viewer = $0 })",
    "Binding(retaining: $viewer, fallback: state)",
    'let text = "Binding($viewer)"',
    "// Binding($viewer)",
    "if let state = Binding($viewer) { // binding-lint: ok pinned by a test",
])
def test_safe_bindings_pass(tmp_path: Path, line: str) -> None:
    assert _rules(tmp_path, SCREEN, f"{line}\n") == []


@pytest.mark.parametrize("line", ["@SceneStorage(\"pal.viewer\") private var open = \"\"", "@AppStorage(\"viewer\") var last = 0"])
def test_viewers_do_not_persist_state(tmp_path: Path, line: str) -> None:
    assert _rules(tmp_path, HOST, f"{line}\n") == ["viewer-no-restore"]


def test_scene_storage_outside_viewers_is_fine(tmp_path: Path) -> None:
    assert _rules(tmp_path, "App/PalApp.swift", '@SceneStorage("pal.openChat") private var restoredChat = ""\n') == []


def test_cli_exits_nonzero_on_a_finding(tmp_path: Path) -> None:
    _rules(tmp_path, HOST, "if let s = Binding($viewer) { }\n")
    result = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path)], capture_output=True, text=True, check=False)
    assert result.returncode == 1
    assert "binding-force-unwrap" in result.stdout


def test_repo_tree_is_clean() -> None:
    assert cfb.scan(REPO / "apps" / "ios") == []
