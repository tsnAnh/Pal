"""scripts/ci/check_swift_bot_settings.py: Mac bot settings screens go through the shared shell."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_bot_settings.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_bot_settings as lint

GOOD = """
struct BotKeysScreen: View {
    var body: some View {
        BotSettingsScreen(title: "Keys", identifier: "botKeysScreen") { content }
    }
}
"""

PRE_SHELL = """
struct BotKeysScreen: View {
    var body: some View {
        ScrollView { content }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Keys").hermesText(.sheetTitle) }
            }
    }
}
"""


def _tree(tmp_path: Path, body: str) -> Path:
    for rel in lint.SCREENS:
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(GOOD, encoding="utf-8")
    (tmp_path / lint.SCREENS[2]).write_text(body, encoding="utf-8")
    return tmp_path


def test_a_screen_in_the_shell_is_clean(tmp_path: Path) -> None:
    assert lint.scan(_tree(tmp_path, GOOD)) == []


def test_a_screen_with_its_own_header_fails_both_rules_and_names_the_shell(tmp_path: Path) -> None:
    found = lint.scan(_tree(tmp_path, PRE_SHELL))
    assert {f.rule for f in found} == {"bot-settings-shell", "bot-settings-own-header"}
    assert all("BotSettingsScreen" in f.message for f in found)


def test_the_opt_out_waives_the_header_rule_only(tmp_path: Path) -> None:
    body = GOOD.replace("{ content }", "{ content }\n.toolbar { ToolbarItem(placement: .principal) { x } } // bot-settings-lint: ok")
    assert lint.scan(_tree(tmp_path, body)) == []


def test_the_real_tree_is_clean() -> None:
    proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout
