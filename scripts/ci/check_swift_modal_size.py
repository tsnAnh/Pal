#!/usr/bin/env python3
"""Fail when a Mac modal carries its own size or a Mac alert goes around the shared dialog.

Every Mac dialog takes 70% of the window, never under 640 x 440 or over 90% (``MacModalSizing.frame(window:)``,
PalDesign), or is content-sized and capped at that size (``MacModalPanel(fit: .content)``). The size lives in the shared modal
container, ``MacModalPanel`` (App/Mac/MacModalSupport.swift); a panel never carries a ``width:`` or ``height:``,
and a Mac modal view never frames its own root with a number. System ``.alert`` and ``.confirmationDialog`` cannot
be resized, so on Mac every alert and confirmation goes through ``.macAlert`` / ``.macConfirm`` (PalDesign
``MacDialog``), which keep the system dialog on iPhone and iPad.

Rules (each finding names the file, line and the fix):

* modal-panel-size: ``MacModalPanel`` declares or is given a ``width:`` or ``height:``.
* modal-root-frame: the root of a Mac modal view (``MacPalette``, ``MacCreateBot``, ``MacRenameBot``,
  ``MacShortcutsSheet``, ``MacSettingsModal``, ``MacConnectAppsPanel``) has a literal ``.frame`` size.
* modal-system-alert: ``.alert(`` or ``.confirmationDialog(`` in code that compiles for Mac.
* modal-env-scope: an ``.overlay`` or ``.background`` follows ``.macModalEnvironment()`` in the same modifier
  chain. Environment flows only into the view it modifies, so a ``MacModalHost`` attached after it gets no window
  size or dialog centre and its panels collapse.

Code inside ``#if os(iOS)`` and ``.iOSOnly { }`` is not Mac code. A justified exception carries
``modal-size: ok <reason>`` on the line.

Run: python scripts/ci/check_swift_modal_size.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "modal-size: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build", "Tools"}
DIALOG_IMPLEMENTATION = "Packages/PalDesign/Sources/PalDesign/Components/MacDialog.swift"
PANEL_FILE = "App/Mac/MacModalSupport.swift"
MODAL_ROOTS = {
    "App/Mac/MacPalette.swift": "MacPalette",
    "App/Mac/MacCreateBot.swift": "MacCreateBot",
    "App/Mac/MacRenameBot.swift": "MacRenameBot",
    "App/Mac/MacCommands.swift": "MacShortcutsSheet",
    "App/Mac/MacSettings.swift": "MacSettingsModal",
    "App/ConnectApps/ConnectAppsMacPanel.swift": "MacConnectAppsPanel",
}
SYSTEM_ALERT = re.compile(r"(?<!SharePresenter)\.(alert|confirmationDialog)\(")
PANEL_SIZE_LABEL = re.compile(r"(?<![A-Za-z0-9_.])(width|height)\s*:")
PANEL_SIZE_DECL = re.compile(r"^\s*(?:let|var)\s+(width|height)\s*:")
ROOT_FRAME = re.compile(r"^\s{8}\.frame\([^\n]*\b(?:width|height|minWidth|minHeight|idealWidth|idealHeight)\s*:\s*\d")
IF_OS = re.compile(r"^\s*#if\s+os\((macOS|iOS)\)\s*$")
FIX_PANEL = (
    "MacModalPanel sizes itself from the window (MacModalSizing.frame(window:), 70%); "
    "drop it, or pass fit: .content for a content-sized dialog"
)
FIX_ROOT = "size comes from MacModalPanel (70% of the window, or fit: .content); read a number from MacModalSizing"
MODAL_ENV = ".macModalEnvironment()"
CHAIN_ATTACH = re.compile(r"^\s*\.(overlay|background)\b")
FIX_ENV = "apply .macModalEnvironment() last, after every .overlay and .background, so the modal host inherits it"
FIX_ALERT = "use .macAlert(...) or .macConfirm(...) (PalDesign MacDialog) so Mac shows the shared dialog at its content size, capped at 70% of the window"


def _swift_files(root: Path) -> list[Path]:
    found = []
    for base in (root / "App", root / "Packages"):
        for path in sorted(base.rglob("*.swift")):
            if not SKIP_DIRS.intersection(path.relative_to(root).parts):
                found.append(path)
    return found


def _read(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8-sig").splitlines()


def _block_end(lines: list[str], start: int) -> int:
    depth = 0
    seen = False
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        seen = seen or "{" in lines[index]
        if seen and depth <= 0:
            return index
    return len(lines) - 1


def _panel_calls(lines: list[str]) -> list[tuple[int, str]]:
    found = []
    for i, line in enumerate(lines):
        position = line.find("MacModalPanel(")
        if position < 0 or OPT_OUT in line:
            continue
        depth = 0
        arguments = []
        done = False
        for j in range(i, len(lines)):
            text = lines[j][position:] if j == i else lines[j]
            for char in text:
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        done = True
                        break
                if depth >= 1:
                    arguments.append(char)
            arguments.append("\n")
            if done:
                break
        top = []
        level = 0
        for char in "".join(arguments)[1:]:
            level += char in "({["
            level -= char in ")}]"
            top.append(char if level == 0 else " ")
        if PANEL_SIZE_LABEL.search("".join(top)):
            found.append((i, "call"))
    return found


def _panel_findings(root: Path) -> list[str]:
    found = []
    for path in _swift_files(root):
        rel = path.relative_to(root).as_posix()
        lines = _read(path)
        if rel == PANEL_FILE:
            start = next((i for i, line in enumerate(lines) if line.startswith("struct MacModalPanel")), None)
            for i in range(start or 0, _block_end(lines, start) + 1 if start is not None else 0):
                if PANEL_SIZE_DECL.match(lines[i]) and OPT_OUT not in lines[i]:
                    found.append(f"{rel}:{i + 1}: modal-panel-size: {FIX_PANEL}")
        for i, _ in _panel_calls(lines):
            found.append(f"{rel}:{i + 1}: modal-panel-size: {FIX_PANEL}")
    return found


def _root_findings(root: Path) -> list[str]:
    found = []
    for rel, struct in MODAL_ROOTS.items():
        path = root / rel
        if not path.is_file():
            continue
        lines = _read(path)
        start = next((i for i, line in enumerate(lines) if re.match(rf"^\s*struct {struct}\b", line)), None)
        if start is None:
            continue
        body = next((i for i in range(start, _block_end(lines, start) + 1) if re.match(r"^\s{4}var body: some View\b", lines[i])), None)
        if body is None:
            continue
        for i in range(body, _block_end(lines, body) + 1):
            if ROOT_FRAME.match(lines[i]) and OPT_OUT not in lines[i]:
                found.append(f"{rel}:{i + 1}: modal-root-frame: {struct} frames its root with a literal; {FIX_ROOT}")
    return found


def _alert_findings(root: Path) -> list[str]:
    found = []
    for path in _swift_files(root):
        rel = path.relative_to(root).as_posix()
        if rel == DIALOG_IMPLEMENTATION:
            continue
        lines = _read(path)
        branches: list[tuple[str, bool]] = []
        ios_only_until = -1
        for i, line in enumerate(lines):
            stripped = line.strip()
            match = IF_OS.match(line)
            if match:
                branches.append((match.group(1), match.group(1) == "iOS"))
            elif stripped.startswith("#if "):
                branches.append(("other", False))
            elif stripped == "#else" and branches:
                kind, _ = branches[-1]
                branches[-1] = (kind, kind == "macOS")
            elif stripped == "#endif" and branches:
                branches.pop()
            if ".iOSOnly" in line and i > ios_only_until:
                ios_only_until = _block_end(lines, i)
            if any(ios for _, ios in branches) or i <= ios_only_until:
                continue
            if SYSTEM_ALERT.search(line) and OPT_OUT not in line:
                found.append(f"{rel}:{i + 1}: modal-system-alert: system {SYSTEM_ALERT.search(line).group(1)} cannot be sized; {FIX_ALERT}")
    return found


def _env_scope_findings(root: Path) -> list[str]:
    found = []
    for path in _swift_files(root):
        rel = path.relative_to(root).as_posix()
        lines = _read(path)
        for i, line in enumerate(lines):
            if MODAL_ENV not in line or OPT_OUT in line or line.lstrip().startswith("func "):
                continue
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, len(lines)):
                text = lines[j]
                stripped = text.strip()
                if not stripped or stripped.startswith(("#if", "#else", "#endif", "//", "}", ")")):
                    continue
                depth = len(text) - len(text.lstrip())
                if depth < indent or (depth == indent and not stripped.startswith(".")):
                    break
                if depth == indent and CHAIN_ATTACH.match(text):
                    found.append(f"{rel}:{i + 1}: modal-env-scope: .{CHAIN_ATTACH.match(text).group(1)} at line {j + 1} sits outside it; {FIX_ENV}")
                    break
    return found


def scan(root: Path) -> list[str]:
    if not (root / "App" / "Mac").is_dir():
        return []
    return _panel_findings(root) + _root_findings(root) + _alert_findings(root) + _env_scope_findings(root)


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} Mac modal size finding(s). Sizes live in MacModalPanel and MacModalSizing; alerts use .macAlert and .macConfirm.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
