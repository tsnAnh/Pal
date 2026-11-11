"""scripts/ci/check_swift_brand.py: the Pal apps never show the word Hermes to a person."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_brand.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_brand as csb


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize("line", [
    'Text("Connect to your Hermes")',
    'let message = String(localized: "Hermes restarted.")',
    'Button("Restart Hermes") {}',
    '.navigationTitle("Hermes service")',
    '.accessibilityLabel("Hermes address")',
    'Text("Sign in to \\(app.name) on your Hermes first.")',
    'let s = """\n  multi\n  line Hermes\n  """',
    'Text("a \\(x ?? "y") Hermes")',
    'Text(#"raw Hermes"#)',
])
def test_user_visible_hermes_fails(tmp_path: Path, line: str) -> None:
    root = _tree(tmp_path, {"App/View.swift": f"import SwiftUI\n{line}\n"})
    assert len(csb.scan(root)) == 1


@pytest.mark.parametrize("body", [
    "import HermesClient\n",
    'let id = "dev.tsnanh.hermes.bot"\nlet k = "hermes.chat.lastSeen."\n',
    'let m = "gateway.service.restart"\nlet p = "hermes-gateway-v1"\n',
    'let u = URL(string: "https://hermes-agent.nousresearch.com/Hermes")\n',
    'struct HermesServiceScreen { let id = "hermesServiceScreen" }\n',
    '// Hermes comment\n/* Hermes block */\nlet x = 1\n',
    'let ok = "Hermes" // brand: ok\n',
    'Text("Pal address")\n',
])
def test_non_visible_hermes_passes(tmp_path: Path, body: str) -> None:
    assert csb.scan(_tree(tmp_path, {"App/File.swift": body})) == []


def test_test_targets_are_exempt(tmp_path: Path) -> None:
    root = _tree(tmp_path, {
        "Packages/HermesKit/Tests/HermesKitTests/T.swift": 'let a = "Hermes"\n',
        "UITests/U.swift": 'let a = "Hermes"\n',
    })
    assert csb.scan(root) == []


def test_planted_example_fails_the_cli(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"App/Planted.swift": 'Text("Welcome to Hermes")\n'})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Planted.swift:1" in proc.stdout


def test_real_apps_ios_tree_is_clean() -> None:
    assert csb.scan(REPO / "apps" / "ios") == []
