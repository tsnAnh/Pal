"""scripts/ci/check_swift_bot_tint.py: Pal surface backgrounds never take a bot accent."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_bot_tint.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_bot_tint as cbt


def _tree(tmp_path: Path, body: str, rel: str = "App/View.swift") -> Path:
    path = tmp_path / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize("tinted, neutral", [
    ("ChatList().background(model.chatAccent?.accent ?? .clear)\n",
     "ChatList().background(Color(theme.palette.canvas))\n"),
    ("Sidebar().containerBackground(Color(hexString: bot.botAccent.accentHex), for: .window)\n",
     "Sidebar().containerBackground(PalTokens.content, for: .window)\n"),
    ("let palette = PalPalette(canvas: RGB(hexString: botAccent.accentHex)!)\n",
     "let palette = PalPalette(canvas: RGB(hex: 0x121212))\n"),
    ("Inspector().tint(chatAccent?.accent)\n",
     "Inspector().tint(Color(theme.palette.accentBlue))\n"),
    ("return PalPalette.measuredDark.tinted(toward: accent)\n",
     "return PalPalette.measuredDark\n"),
])
def test_accent_surface_fails_and_neutral_token_passes(tmp_path: Path, tinted: str, neutral: str) -> None:
    found = cbt.scan(_tree(tmp_path / "red", tinted))
    assert found and found[0].startswith("App/View.swift:1:")
    assert cbt.scan(_tree(tmp_path / "green", neutral)) == []


@pytest.mark.parametrize("body", [
    "Image(systemName: \"paperplane\").background(model.chatAccent?.accent ?? .clear, in: Circle())\n",
    "Text(\"Allow\").background(chatAccent?.accent ?? .blue, in: Capsule())\n",
    "Circle().fill(accent?.accent ?? PalTokens.inverseFill)\n",
    "BotAvatarView(spec: spec).foregroundStyle(chatAccent?.foreground ?? .white)\n",
    "Panel().background(chatAccent?.accent) // bot-tint: ok\n",
])
def test_small_accent_shapes_and_opt_out_pass(tmp_path: Path, body: str) -> None:
    assert cbt.scan(_tree(tmp_path, body)) == []


def test_tests_are_skipped(tmp_path: Path) -> None:
    root = _tree(tmp_path, "List().background(chatAccent?.accent)\n", "Packages/X/Tests/T.swift")
    assert cbt.scan(root) == []


def test_cli_exit_codes(tmp_path: Path) -> None:
    red = _tree(tmp_path / "red", "List().background(chatAccent?.accent)\n")
    green = _tree(tmp_path / "green", "List().background(PalTokens.content)\n")
    run = lambda root: subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    failing = run(red)
    assert failing.returncode == 1 and "bot tint finding" in failing.stdout
    assert run(green).returncode == 0


def test_pal_tree_is_clean() -> None:
    assert cbt.scan(REPO / "apps" / "ios") == []
