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
* an armed edge position (``ScrollPosition(... edge:`` and ``scrollTo(edge:``) re-resolves the bottom on its own, a second
  writer next to the machine (it left the list 61 pt short of the bottom and flashed 92 pt past it): allowed only on the
  ``ARMED_EDGE_ALLOWED`` lines of ``ChatScrollController.swift``, and only while that file keeps the ``edgeIsArmed`` release
  that hands the position back once the machine is at the bottom;
* any ``.defaultScrollAnchor(`` outside ``SYSTEM_ANCHORS`` (the one system anchor that keeps the bottom while rows grow);
* ``ChatScrollController.swift`` must reference ``ChatScrollMachine``;
* ``observe(_ geometry:)`` and ``rowLaidOut`` run inside the scroll view's layout commit: they hand their command to
  ``performNextTurn(`` (one write on the next run-loop turn), never to ``perform(`` (a write inside the commit
  re-runs the whole list and froze a 14,000-message chat). The one exception is ``repairInPass(``: a pinned list that is
  short of the bottom is repaired in the pass that moved it (the composer inset growing, the newest row growing), because a
  repair one turn later leaves the list 7 to 36 pt short for one to three frames. It writes at most once per run-loop turn
  and hands any further repair to the next turn; without that limit the commit loops and the app hangs;
* the transcript ``ForEach`` in ``ChatTranscriptList.swift`` iterates ``model.windowRows``, never ``model.rows``
  (the full transcript; a long chat would lay out thousands of rows);
* the transcript ``ForEach`` renders the planned tail (``windowRows[plan.start...]``), never the whole window: rows
  before the tail are one ``ChatHiddenRowsSpacer`` of their known height (a ``LazyVStack`` estimates every unrealized
  row from the realized ones, and a tall tail row inflated the content to four times its settled height);
* reading ``contentOffset`` is allowed only in ``ChatScrollController.swift`` and ``ChatScrollTrace.swift``;
* the chat list has ONE row height owner: ``ChatRowHeightCache`` is named only in ``ChatRowHeights.swift`` (the
  object ``ChatScrollController`` owns; rows are measured and laid out through it), and the transcript list sets a row height frame only inside
  ``ChatRowHeightFloor`` (a second height source re-introduces rows whose height is guessed and later replaced).

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
HEIGHT_FIX = "give the row its height through ChatScrollController and ChatRowHeights (measured, minHeight(for:)) and ChatRowHeightFloor only"
TAIL_FIX = "iterate the planned tail (windowRows[plan.start...]) and give the rows before it to ChatHiddenRowsSpacer"
HEIGHT_OWNER = "App/Chat/ChatRowHeights.swift"
SEND_VIEW = "App/Chat/ChatView+Bottom.swift"
SEND_CALL = re.compile(r"\bmodel\.send\(")
SEND_TRANSACTION = re.compile(r"\bwithTransaction\b")
SEND_FIX = ("the send closure changes the composer, the draft and the rows inside one non-animating withTransaction "
            "(Transaction.disablesAnimations); an animated composer or notice collapse drives a geometry event per frame into the scroll machine")
WHOLE_ROW_COMPARE = re.compile(r"!=\s*row\b(?!\.)|\brow\s*!=")
LAYOUT_KEY_FIX = ("compare row.layoutKey, not the whole row: a delivery state change must not forget a measured height, "
                  "and a forgotten height is measured again and moves the list")
HEIGHT_CACHE = re.compile(r"\bChatRowHeightCache\b")
ROW_HEIGHT_FRAME = re.compile(r"\.frame\(\s*(?:minHeight|height)\s*:")
HEIGHT_FLOOR = re.compile(r"\bstruct ChatRowHeightFloor\b")
PERFORM = re.compile(r"\bfunc perform\(")
LAYOUT_CALLBACK = re.compile(r"\bfunc (?:observe\(_ geometry|rowLaidOut)\b")
DIRECT_PERFORM = re.compile(r"(?<![\w.])perform\(")
FULL_TRANSCRIPT_LOOP = re.compile(r"\bForEach\(\s*model\.rows\b")
WHOLE_WINDOW_LOOP = re.compile(r"\bForEach\(\s*(?:model\.)?windowRows\s*\)")
HIDDEN_SPACER = re.compile(r"\bstruct ChatHiddenRowsSpacer\b")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
OFFSET_READ = re.compile(r"\bcontentOffset\b")
SCROLL_POSITION = ".scrollPosition("
SYSTEM_ANCHORS = {LIST_VIEW: (".defaultScrollAnchor(.bottom)",)}
ARMED_EDGE = re.compile(r"\bScrollPosition\([^)]*\bedge:\s*\.bottom|\bscrollTo\(\s*edge:\s*\.bottom")
DEFAULT_ANCHOR = re.compile(r"\.defaultScrollAnchor\(")
ARMED_EDGE_ALLOWED = {
    CONTROLLER: ("ScrollPosition(idType: String.self, edge: .bottom)", "position.scrollTo(edge: .bottom)"),
}
ARMED_RELEASE = "edgeIsArmed"
RELEASE_FIX = "the controller arms an edge position but has no edgeIsArmed release; an edge that is never released is a second writer"
ARMED_EDGE_FIX = ("write the bottom with scrollTo(y:) from ChatScrollController.perform; an armed edge position is a second writer "
                  "that re-resolves the bottom on its own")
ANCHOR_FIX = "the chat list has one system anchor, listed in SYSTEM_ANCHORS; a second anchor is a second writer next to the machine"
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


def body_lines(lines: list[tuple[int, str, str]], opening: re.Pattern[str]) -> set[int]:
    inside: set[int] = set()
    depth = 0
    open_body = False
    tracking = False
    for number, _, code in lines:
        if not tracking and opening.search(code):
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


def owner_rule(rel: str, code: str, transaction_seen: bool) -> tuple[str, str] | None:
    if rel == SEND_VIEW and SEND_CALL.search(code) and not transaction_seen:
        return "a send outside a withTransaction", SEND_FIX
    if rel == HEIGHT_OWNER and WHOLE_ROW_COMPARE.search(code):
        return "a whole-row comparison in the height owner", LAYOUT_KEY_FIX
    return None


def transcript_loop_rule(code: str) -> tuple[str, str] | None:
    if FULL_TRANSCRIPT_LOOP.search(code):
        return "the transcript ForEach over model.rows (the whole transcript); iterate model.windowRows", FIX
    if WHOLE_WINDOW_LOOP.search(code):
        return "the transcript ForEach over the whole window", TAIL_FIX
    return None


def second_writer_findings(rel: str, raw: str, code: str) -> list[tuple[str, str]]:
    found = []
    if ARMED_EDGE.search(code) and not any(allowed in raw for allowed in ARMED_EDGE_ALLOWED.get(rel, ())):
        found.append(("an armed edge scroll position", ARMED_EDGE_FIX))
    if DEFAULT_ANCHOR.search(code) and not any(allowed in raw for allowed in SYSTEM_ANCHORS.get(rel, ())):
        found.append(("a defaultScrollAnchor outside the system anchor allowlist", ANCHOR_FIX))
    return found


def controller_findings(root: Path) -> list[str]:
    controller = root / CONTROLLER
    text = controller.read_text(encoding="utf-8-sig") if controller.is_file() else ""
    found = []
    if "ChatScrollMachine" not in text:
        found.append(f"{CONTROLLER}:1: the scroll controller does not reference ChatScrollMachine; {FIX}")
    if "edge: .bottom" in text and ARMED_RELEASE not in text:
        found.append(f"{CONTROLLER}:1: {RELEASE_FIX}")
    return found


def scan(root: Path, allowlist: Path = ALLOWLIST) -> list[str]:
    waivers, found = parse_allowlist(allowlist)
    used: set[Waiver] = set()
    scroll_positions: dict[str, list[int]] = {}

    def report(rel: str, number: int, raw: str, what: str, fix: str = FIX) -> None:
        for waiver in waivers:
            if waiver.path == rel and waiver.needle in raw:
                used.add(waiver)
                return
        found.append(f"{rel}:{number}: {what}; {fix}")

    for path in chat_files(root):
        rel = path.relative_to(root).as_posix()
        lines = code_lines(path.read_text(encoding="utf-8-sig"))
        writer = body_lines(lines, PERFORM) if rel == CONTROLLER else set()
        layout = body_lines(lines, LAYOUT_CALLBACK) if rel == CONTROLLER else set()
        floor = body_lines(lines, HEIGHT_FLOOR) | body_lines(lines, HIDDEN_SPACER) if rel == LIST_VIEW else set()
        transaction_seen = False
        for number, raw, code in lines:
            flagged = False
            if owner_finding := owner_rule(rel, code, transaction_seen):
                report(rel, number, raw, *owner_finding)
                flagged = True
            transaction_seen = transaction_seen or (rel == SEND_VIEW and bool(SEND_TRANSACTION.search(code)))
            if number in layout and DIRECT_PERFORM.search(code):
                report(rel, number, raw, "a scroll write inside the layout commit (perform( in a layout callback); use performNextTurn(")
                flagged = True
            if rel == LIST_VIEW and (loop := transcript_loop_rule(code)):
                report(rel, number, raw, *loop)
                flagged = True
            if rel != HEIGHT_OWNER and HEIGHT_CACHE.search(code):
                report(rel, number, raw, "a second row height owner (ChatRowHeightCache outside ChatRowHeights)", HEIGHT_FIX)
                flagged = True
            if rel == LIST_VIEW and number not in floor and ROW_HEIGHT_FRAME.search(code):
                report(rel, number, raw, "a row height frame outside ChatRowHeightFloor", HEIGHT_FIX)
                flagged = True
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
            for what, fix in second_writer_findings(rel, raw, code):
                report(rel, number, raw, what, fix)
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
    found.extend(controller_findings(root))
    for waiver in waivers:
        if waiver not in used:
            found.append(f"{allowlist.name}:{waiver.line}: allowlist entry {waiver.path}:{waiver.needle} matches nothing; delete it")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    if not (root / "App" / "Chat").is_dir():
        return 0
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat scroll writer finding(s). The chat list has one scroll writer: {FIX}.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
