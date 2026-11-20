#!/usr/bin/env python3
"""Fail when the chat list can scroll or sit sideways.

The chat list scrolls vertically only. Two things keep it there:

* on iPhone and iPad the scrolled content is pinned to the viewport width with ``containerRelativeFrame(.horizontal)``
  in ``App/ChatView.swift`` (inside ``#if os(iOS)``), so a wide row (table, code, image) can never widen the list;
  wide content scrolls inside its own horizontal ScrollView;
* on Mac that modifier is forbidden: it resolves against the window, not the pane ``MacShellLayout`` proposes, so the
  chat content is as wide as the window and overflows it by the sidebar width. The Mac list is bounded by
  ``.chatColumn()`` alone;
* every programmatic scroll of the list (``ChatView.swift``, ``ChatScrollController.swift``) sets only the vertical axis: ``scrollTo(edge: .top)``,
  ``scrollTo(edge: .bottom)``, ``scrollTo(y:)`` or ``scrollTo(id:, anchor: ChatScrollController.revealAnchor)``
  (an anchor with ``x: 0``). ``scrollTo(x:)``, ``scrollTo(point:)``, a leading or trailing edge and a centred
  anchor carry an x and move the list sideways. A justified exception carries ``chat-scroll: ok`` on the line.

Run: python scripts/ci/check_swift_chat_scroll.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "chat-scroll: ok"
LIST_FILES = ("App/ChatView.swift", "App/Chat/ChatScrollController.swift")
SCROLL_CALL = re.compile(r"\.scrollTo\(")
VERTICAL_ONLY = re.compile(
    r"\.scrollTo\((?:edge: \.(?:top|bottom)\)|y:|id: [^,()]+, anchor: (?:ChatScrollController\.|Self\.)?revealAnchor\))"
)
WIDTH_PIN = "containerRelativeFrame(.horizontal"
FIX = ("Scroll the chat list on the vertical axis only: scrollTo(edge: .top), scrollTo(y:) or scrollTo(id:, anchor: "
       "ChatScrollController.revealAnchor), and keep containerRelativeFrame(.horizontal) on the list content in ChatView.swift "
       "inside #if os(iOS) only.")
MAC_PIN = ("containerRelativeFrame(.horizontal) in the macOS build of the chat list: on Mac it resolves against the window, "
           "not the pane MacShellLayout proposes, so the content is as wide as the whole window and overflows the pane by the "
           "sidebar width. Put the pin inside #if os(iOS) and bound the Mac list with .chatColumn() alone")
IOS_PIN = "the list content is not pinned to the viewport width on iOS; add containerRelativeFrame(.horizontal) inside #if os(iOS)"
CONDITIONAL = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
OS_TEST = re.compile(r"\bos\((\w+)\)")


def _holds(condition: str, target: str) -> bool:
    expr = OS_TEST.sub(lambda m: "T" if m.group(1) == target else "F", condition)
    expr = re.sub(r"\b(?:canImport|targetEnvironment|swift|compiler)\([^)]*\)|\b[A-Z_]{3,}\b", "F", expr)
    tokens = re.findall(r"&&|\|\||!|\(|\)|T|F", expr)
    position = 0

    def peek() -> str:
        return tokens[position] if position < len(tokens) else ""

    def take() -> str:
        nonlocal position
        position += 1
        return tokens[position - 1]

    def either() -> bool:
        value = both()
        while peek() == "||":
            take()
            value = both() or value
        return value

    def both() -> bool:
        value = unary()
        while peek() == "&&":
            take()
            value = unary() and value
        return value

    def unary() -> bool:
        token = take() if peek() else "F"
        if token == "!":
            return not unary()
        if token == "(":
            value = either()
            if peek() == ")":
                take()
            return value
        return token == "T"

    return either()


def active_lines(text: str, target: str) -> list[tuple[int, str]]:
    frames: list[list[bool]] = []
    active = []
    for number, line in enumerate(text.splitlines(), 1):
        directive = CONDITIONAL.match(line)
        if directive:
            kind, rest = directive.groups()
            if kind == "if":
                frames.append([_holds(rest, target), _holds(rest, target)])
            elif kind == "elseif" and frames:
                taken = frames[-1][1]
                frames[-1][0] = not taken and _holds(rest, target)
                frames[-1][1] = taken or frames[-1][0]
            elif kind == "else" and frames:
                frames[-1][0] = not frames[-1][1]
                frames[-1][1] = True
            elif kind == "endif" and frames:
                frames.pop()
            continue
        if all(frame[0] for frame in frames):
            active.append((number, line))
    return active


def list_files(root: Path) -> list[Path]:
    return [path for path in (root / name for name in LIST_FILES) if path.is_file()]


def scan(root: Path) -> list[str]:
    found = []
    for path in list_files(root):
        rel = path.relative_to(root).as_posix()
        for i, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines()):
            if OPT_OUT in line or not SCROLL_CALL.search(line):
                continue
            if not VERTICAL_ONLY.search(line):
                found.append(f"{rel}:{i + 1}: programmatic scroll that can set an x; use a vertical-only target")
    view = root / "App" / "ChatView.swift"
    if view.is_file():
        text = view.read_text(encoding="utf-8-sig")
        for number, line in active_lines(text, "macOS"):
            if WIDTH_PIN in line and OPT_OUT not in line:
                found.append(f"App/ChatView.swift:{number}: {MAC_PIN}")
        if not any(WIDTH_PIN in line for _, line in active_lines(text, "iOS")):
            found.append(f"App/ChatView.swift:1: {IOS_PIN}")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat scroll finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
