#!/usr/bin/env python3
"""Fail when a Mac bot settings screen builds its own header instead of the shared shell.

The screens behind the bot info panel rows share one family: ``BotSettingsScreen``
(App/Profile/BotSettingsScreen.swift) draws the title pill with the bot avatar, the clear-glass X at the top
right, Back at the top left on nested steps, Esc, and the 560 pt column. Text matching only (no Swift
toolchain); reuses the comment- and string-blanking ``Source`` scanner of ``check_swift_glass.py``.

Rules: bot-settings-shell, bot-settings-own-header. A justified exception carries ``bot-settings-lint: ok``.

Run: python scripts/ci/check_swift_bot_settings.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import Finding, Source

OPT_OUT = "bot-settings-lint: ok"
SHELL = "BotSettingsScreen"
SCREENS = (
    "App/Profile/BotModelView.swift",
    "App/Profile/MessagingSettingsView.swift",
    "App/Settings/BotKeysScreen.swift",
)
USES_SHELL = re.compile(rf"(?<![A-Za-z0-9_]){SHELL}\(")
OWN_HEADER = re.compile(r"ToolbarItem\(\s*placement:\s*\.principal|\.hermesText\(\s*\.sheetTitle|(?<![A-Za-z0-9_])SheetChrome\(\s*title")
SHELL_MESSAGE = (f"bot settings screen does not go through {SHELL}. Wrap its content in {SHELL}(title:identifier:...) "
                 "so it gets the shared header, X, Back, Esc and column")
HEADER_MESSAGE = (f"own header in a bot settings screen. The title, X and Back come from {SHELL}; "
                  "remove the toolbar title or SheetChrome title here")


def violations(rel: str, source: str) -> list[Finding]:
    src = Source(source)
    found: list[Finding] = []
    if not any(USES_SHELL.search(line) for line in src.plain):
        found.append(Finding("bot-settings-shell", rel, 1, "", SHELL_MESSAGE))
    for i, code in enumerate(src.plain):
        if OWN_HEADER.search(code) and OPT_OUT not in src.original[i]:
            found.append(Finding("bot-settings-own-header", rel, i + 1, src.original[i].strip(), HEADER_MESSAGE))
    return found


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    if not (root / "App").is_dir():
        return found
    for rel in SCREENS:
        path = root / rel
        if not path.is_file():
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} bot settings finding(s). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
