#!/usr/bin/env python3
"""Fail when anything but ChatScrollController.perform writes the chat list's scroll position.

The chat list has ONE scroll writer. ChatScrollMachine (PalKit) turns events into commands and
``func perform(`` in ``App/Chat/ChatScrollController.swift`` is the only place that applies them. Everything
else in ``App/Chat/**/*.swift``, ``App/ChatView*.swift`` and ``App/Platform/ChatPlatform.swift`` only emits events.

* forbidden outside ``perform``: ``scrollTo(``, ``ScrollViewProxy``, ``ScrollViewReader``, ``setContentOffset``,
  ``contentOffset =``, ``scroll(to:``, ``scrollToVisible``, ``reflectScrolledClipView``;
* forbidden everywhere: ``scaleEffect(x: 1, y: -1`` (the flipped list), ``.contentMargins(`` (the mirrored composer
  inset; the composer rides ``palSafeAreaBar``), a ``.scrollPosition(`` outside ``App/Chat/ChatTranscriptList.swift``
  and a second one inside it;
* ``ChatScrollController.swift`` must reference ``ChatScrollMachine``;
* reading ``contentOffset`` is allowed only in ``ChatScrollController.swift`` and ``ChatScrollTrace.swift``.

``scripts/ci/chat_scroll_single_writer_allowlist.txt`` waives a needle in one file for a list that is not the
transcript. One entry per line, ``path:needle -- reason``, the reason required. The per-line ``chat-scroll: ok``
marker does not apply to this rule.

Run: python scripts/ci/check_swift_chat_scroll_writer.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

CONTROLLER = "App/Chat/ChatScrollController.swift"
LIST_VIEW = "App/Chat/ChatTranscriptList.swift"
OFFSET_READERS = frozenset({CONTROLLER, "App/Chat/ChatScrollTrace.swift"})
PLATFORM = "App/Platform/ChatPlatform.swift"
ALLOWLIST = Path(__file__).with_name("chat_scroll_single_writer_allowlist.txt")
FIX = "route it through ChatScrollMachine: emit a command and let ChatScrollController.perform apply it"
PERFORM = re.compile(r"\bfunc perform\(")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
OFFSET_READ = re.compile(r"\bcontentOffset\b")
SCROLL_POSITION = ".scrollPosition("
WRITES = (
    (re.compile(r"\bscrollTo\("), "a programmatic scroll"),
    (re.compile(r"\bScrollViewProxy\b"), "a ScrollViewProxy"),
    (re.compile(r"\bScrollViewReader\b"), "a ScrollViewReader"),
    (re.compile(r"\bsetContentOffset\b"), "setContentOffset"),
    (re.compile(r"\bcontentOffset\s*=(?!=)"), "an assignment to contentOffset"),
    (re.compile(r"\bscroll\(to:"), "scroll(to:)"),
    (re.compile(r"\bscrollToVisible\b"), "scrollToVisible"),
    (re.compile(r"\breflectScrolledClipView\b"), "reflectScrolledClipView"),
)
ANYWHERE = (
    (re.compile(r"scaleEffect\(x: 1, y: -1"), "the flipped list (scaleEffect(x: 1, y: -1)); the list is top-down"),
    (re.compile(r"\.contentMargins\("), "a mirrored composer inset (.contentMargins); the composer rides palSafeAreaBar(edge: .bottom)"),
)


@dataclass(frozen=True)
class Waiver:
    path: str
    needle: str
    reason: str
    line: int


def parse_allowlist(path: Path) -> tuple[list[Waiver], list[str]]:
    waivers: list[Waiver] = []
    errors: list[str] = []
    if not path.is_file():
        return waivers, errors
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        where = f"{path.name}:{number}"
        spec, separator, reason = entry.partition(" -- ")
        target, colon, needle = spec.partition(":")
        if not separator or not reason.strip():
            errors.append(f"{where}: allowlist entry needs a reason: `path:needle -- reason`")
        elif not colon or not target.strip() or not needle.strip():
            errors.append(f"{where}: allowlist entry needs `path:needle` before ` -- `")
        else:
            waivers.append(Waiver(target.strip(), needle.strip(), reason.strip(), number))
    return waivers, errors


def chat_files(root: Path) -> list[Path]:
    found = set((root / "App" / "Chat").rglob("*.swift"))
    found.update((root / "App").glob("ChatView*.swift"))
    platform = root / PLATFORM
    if platform.is_file():
        found.add(platform)
    return sorted(found)


def code_lines(text: str) -> list[tuple[int, str, str]]:
    result = []
    for number, raw in enumerate(text.splitlines(), 1):
        code = STRING.sub('""', raw).split("//", 1)[0]
        result.append((number, raw, code))
    return result


def perform_lines(lines: list[tuple[int, str, str]]) -> set[int]:
    inside: set[int] = set()
    depth = 0
    open_body = False
    tracking = False
    for number, _, code in lines:
        if not tracking and PERFORM.search(code):
            tracking = True
        if tracking:
            inside.add(number)
            depth += code.count("{") - code.count("}")
            open_body = open_body or "{" in code
            if open_body and depth <= 0:
                tracking = False
                open_body = False
                depth = 0
    return inside


def scan(root: Path, allowlist: Path = ALLOWLIST) -> list[str]:
    waivers, found = parse_allowlist(allowlist)
    used: set[Waiver] = set()
    scroll_positions: dict[str, list[int]] = {}

    def report(rel: str, number: int, raw: str, what: str) -> None:
        for waiver in waivers:
            if waiver.path == rel and waiver.needle in raw:
                used.add(waiver)
                return
        found.append(f"{rel}:{number}: {what}; {FIX}")

    for path in chat_files(root):
        rel = path.relative_to(root).as_posix()
        lines = code_lines(path.read_text(encoding="utf-8-sig"))
        writer = perform_lines(lines) if rel == CONTROLLER else set()
        for number, raw, code in lines:
            flagged = False
            if number not in writer:
                for pattern, what in WRITES:
                    if pattern.search(code):
                        report(rel, number, raw, what)
                        flagged = True
                        break
            for pattern, what in ANYWHERE:
                if pattern.search(code):
                    report(rel, number, raw, what)
                    flagged = True
            if SCROLL_POSITION in code:
                scroll_positions.setdefault(rel, []).append(number)
                if rel != LIST_VIEW:
                    report(rel, number, raw, ".scrollPosition outside ChatTranscriptList.swift")
                    flagged = True
            if not flagged and rel not in OFFSET_READERS and OFFSET_READ.search(code):
                report(rel, number, raw, "a read of contentOffset outside ChatScrollController.swift and ChatScrollTrace.swift")
        if rel == LIST_VIEW and len(scroll_positions.get(rel, [])) > 1:
            number = scroll_positions[rel][1]
            report(rel, number, lines[number - 1][1], "a second .scrollPosition in the chat list")
    controller = root / CONTROLLER
    if not controller.is_file() or "ChatScrollMachine" not in controller.read_text(encoding="utf-8-sig"):
        found.append(f"{CONTROLLER}:1: the scroll controller does not reference ChatScrollMachine; {FIX}")
    for waiver in waivers:
        if waiver not in used:
            found.append(f"{allowlist.name}:{waiver.line}: allowlist entry {waiver.path}:{waiver.needle} matches nothing; delete it")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat scroll writer finding(s). The chat list has one scroll writer: {FIX}.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
