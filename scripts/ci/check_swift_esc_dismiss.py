#!/usr/bin/env python3
"""Fail when a Mac popup is presented, or an ESC handler written, outside the shared ESC mechanism.

Every Mac popup closes with ESC through one stack (PalDesign ``EscapeStack``): a popup registers with ``.palEscape(``
(layer, nested, policy, dismiss), sets its policy with ``.palEscapePolicy(``, and an in-content Cancel button takes
``.palCancelShortcut()``. The presentation layers (``MacModalPanel``, ``MacSheetLayer``, ``MacDialogLayer``,
``macSheet``, ``macAlert`` / ``macConfirm``) register for their content, so a popup built on them gets ESC for free.

Rules (each finding is ``path:line: rule-id: message``):

* esc-presentation: ``.sheet(``, ``.fullScreenCover(``, ``.alert(``, ``.confirmationDialog(``, ``.popover(`` or
  ``NSAlert`` outside a shared file whose presentation block has neither ``.palEscape(`` nor ``SheetChrome(``.
* esc-copy: a per-view ESC handler (``.keyboardShortcut(.cancelAction)``, ``onKeyPress(.escape``, ``onExitCommand``)
  outside a shared file.
* esc-layer-missing: a shared layer file lost the hook that gives its popups ESC.
* esc-allowlist-stale / esc-allowlist-reason: an allowlist entry whose file or pattern is gone, or with no reason.

An exception is one line in ``scripts/ci/esc_dismiss_allowlist.txt``: ``<path relative to apps/ios>:<pattern>  <reason>``.
It covers every occurrence of the literal pattern in that file.

Run: python scripts/ci/check_swift_esc_dismiss.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build", "Tools"}
ALLOWLIST = Path(__file__).with_name("esc_dismiss_allowlist.txt")
ALLOWLIST_NAME = "scripts/ci/esc_dismiss_allowlist.txt"
COMPONENTS = "Packages/PalDesign/Sources/PalDesign/Components/"
SHARED_FILES = {
    "App/Mac/MacModalSupport.swift",
    "App/Mac/MacSheetLayer.swift",
    "App/Mac/MacDialogLayer.swift",
    "App/Platform/MacSheet.swift",
    "App/Platform/PalAlert.swift",
    COMPONENTS + "MacDialog.swift",
    COMPONENTS + "EscapeStack.swift",
    COMPONENTS + "EscapePolicy.swift",
    COMPONENTS + "SheetChrome.swift",
    COMPONENTS + "PalSystemChrome.swift",
}
LAYER_HOOKS = {
    "App/Mac/MacModalSupport.swift": [".palEscape("],
    "App/Mac/MacDialogLayer.swift": [".palEscape(.dialog"],
    "App/Mac/MacSheetLayer.swift": ["MacModalPanel(", "layer: .sheet"],
    COMPONENTS + "EscapeStack.swift": [".keyboardShortcut(.cancelAction)"],
}
PRESENTATION = re.compile(r"\.(?:sheet|fullScreenCover|confirmationDialog|popover)\(|(?<!SharePresenter)\.alert\(|\bNSAlert\b")
ESC_COPY = re.compile(r"\.keyboardShortcut\(\s*\.(?:cancelAction|escape)\b|\bonKeyPress\(\s*\.escape\b|\bonExitCommand\b")
ESC_HOOKS = (".palEscape(", "SheetChrome(")
FIX = (
    "use the shared ESC mechanism: .palEscape(...) / .palEscapePolicy(...) (PalDesign EscapeStack), "
    f"or add a reviewed `path:pattern  reason` line to {ALLOWLIST_NAME}"
)


def _swift_files(root: Path) -> list[Path]:
    found = []
    for base in (root / "App", root / "Packages"):
        for path in sorted(base.rglob("*.swift")):
            if not SKIP_DIRS.intersection(path.relative_to(root).parts):
                found.append(path)
    return found


def _mask(text: str) -> str:
    """The source with comments and string contents blanked, same length, newlines kept."""
    out = list(text)
    i, n = 0, len(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        two = text[i : i + 2]
        if two == "//":
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                pair = text[j : j + 2]
                if pair == "/*":
                    depth, j = depth + 1, j + 2
                elif pair == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            blank(i + 1, end - 1)
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


def _matching(code: str, start: int, open_char: str, close_char: str) -> int:
    depth = 0
    for i in range(start, len(code)):
        if code[i] == open_char:
            depth += 1
        elif code[i] == close_char:
            depth -= 1
            if depth == 0:
                return i
    return len(code) - 1


def _presentation_block(code: str, match: re.Match[str]) -> str:
    end = match.end()
    if match.group(0).endswith("("):
        end = _matching(code, match.end() - 1, "(", ")") + 1
        rest = code[end:]
        trailing = len(rest) - len(rest.lstrip())
        if rest[trailing : trailing + 1] == "{":
            end = _matching(code, end + trailing, "{", "}") + 1
    return code[match.start() : end]


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def load_allowlist(path: Path) -> tuple[list[tuple[int, str, str, str]], list[str]]:
    entries: list[tuple[int, str, str, str]] = []
    problems: list[str] = []
    if not path.is_file():
        return entries, problems
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, reason = line.partition("  ")
        rel, _, pattern = key.partition(":")
        if not rel or not pattern:
            problems.append(f"{ALLOWLIST_NAME}:{number}: esc-allowlist-reason: expected `<path>:<pattern>  <reason>`")
        elif not reason.strip():
            problems.append(f"{ALLOWLIST_NAME}:{number}: esc-allowlist-reason: `{key}` has no reason; say why this popup closes without the shared mechanism")
        else:
            entries.append((number, rel, pattern, reason.strip()))
    return entries, problems


def _file_findings(rel: str, text: str) -> list[tuple[int, str, str, str]]:
    code = _mask(text)
    lines = text.splitlines()
    found = []
    for match in PRESENTATION.finditer(code):
        block = _presentation_block(code, match)
        if not any(hook in block for hook in ESC_HOOKS):
            line = _line_of(code, match.start())
            found.append((line, "esc-presentation", f"{match.group(0)} popup has no .palEscape( or SheetChrome(", lines[line - 1]))
    for match in ESC_COPY.finditer(code):
        line = _line_of(code, match.start())
        found.append((line, "esc-copy", f"per-view ESC handler {match.group(0)}", lines[line - 1]))
    return found


def _layer_findings(root: Path) -> list[str]:
    found = []
    for rel, hooks in LAYER_HOOKS.items():
        path = root / rel
        text = _mask(path.read_text(encoding="utf-8-sig")) if path.is_file() else ""
        for hook in hooks:
            if hook not in text:
                found.append(f"{rel}:1: esc-layer-missing: shared layer lost `{hook}`, so its popups no longer close with ESC; {FIX}")
    return found


def scan(root: Path, allowlist: Path | None = None) -> list[str]:
    if not (root / "App" / "Mac").is_dir():
        return []
    entries, problems = load_allowlist(ALLOWLIST if allowlist is None else allowlist)
    found = list(problems) + _layer_findings(root)
    patterns: dict[str, list[str]] = {}
    for _, rel, pattern, _ in entries:
        patterns.setdefault(rel, []).append(pattern)
    for path in _swift_files(root):
        rel = path.relative_to(root).as_posix()
        if rel in SHARED_FILES:
            continue
        for line, rule, message, source in _file_findings(rel, path.read_text(encoding="utf-8-sig")):
            if not any(pattern in source for pattern in patterns.get(rel, [])):
                found.append(f"{rel}:{line}: {rule}: {message}; {FIX}")
    for number, rel, pattern, _ in entries:
        path = root / rel
        if not path.is_file() or pattern not in path.read_text(encoding="utf-8-sig"):
            found.append(f"{ALLOWLIST_NAME}:{number}: esc-allowlist-stale: `{rel}:{pattern}` matches nothing; delete the entry")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} ESC dismiss finding(s). Every Mac popup closes with ESC through .palEscape( (PalDesign EscapeStack); exceptions are reviewed lines in {ALLOWLIST_NAME}.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
