#!/usr/bin/env python3
"""Fail when Pal Swift code repeats a Mac performance mistake (table in apps/ios/AGENTS.md, "Performance").

Same mechanism as ``check_swift_glass.py`` (text only, no Swift toolchain; its bracket-aware
``Source`` scanner and baseline helpers are reused). Findings already on main sit in
``apps/ios/.perf-lint-baseline.json`` (matched by rule, file and line text); only a NEW finding
fails, and a fix that removes one leaves a stale entry that is reported and harmless
(``--write-baseline`` rewrites the file). Files that may use ``TimelineView``, ``onContinuousHover`` or a
single-instance ``NSEvent`` monitor are listed with a reason in ``apps/ios/.perf-lint-allowlist.json``. A justified
exception carries ``perf-lint: ok`` on the flagged line.

Rules: perf-body-parse, perf-body-format, perf-redraw-per-call, perf-main-disk-read, perf-main-json,
perf-queue-sync, perf-timeline-unlisted, perf-timeline-interval, perf-hover-unlisted,
perf-animation-container, perf-eager-stack, perf-monitor-per-view, perf-geometry-per-row,
perf-state-model-init, perf-model-in-body, perf-shadow-radius, perf-glass-over-fill, perf-unguarded-write,
perf-body-array-work, perf-row-reads-model, perf-observed-image-dictionary, perf-monitor-unpaired, perf-dropped-value,
perf-avatar-row-slot, perf-drag-writes-binding, perf-open-ungated, perf-hover-state-in-row-body, perf-selection-island,
perf-table-in-text-bubble, perf-hover-pill-outside-tracker, perf-hover-tracker-per-bubble.

Run: python scripts/ci/check_swift_perf.py [apps_ios_root] [--write-baseline] [--no-baseline]
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import (
    DECL,
    SKIP_DIRS,
    Finding,
    Source,
    _decls,
    load_baseline,
    new_findings,
    write_baseline,
)

OPT_OUT = "perf-lint: ok"
BASELINE_NAME = ".perf-lint-baseline.json"
ALLOWLIST_NAME = ".perf-lint-allowlist.json"
SKIP = SKIP_DIRS | {"Tools"}
ALLOWLISTED_RULES = ("perf-timeline-unlisted", "perf-hover-unlisted", "perf-monitor-per-view")
SHADOW_MAX_RADIUS = 24
OWNED_TYPE = r"[A-Z]\w*(?:Model|Store|Hub|Conversation|Controller)(?:\.\w+)?"
SHELL_FILES = {("App", "Mac", "MacShell.swift")}
ROW_FILES = {("App", "Chat", "ChatRows.swift"), ("App", "Chat", "AssistantBubble.swift")}
AVATAR_ROW_FILES = {("App", "Mac", "MacSidebar.swift"), ("App", "HomeView.swift"), ("App", "Rooms", "RoomRows.swift")}
GUARDED_WRITE_FIELDS = {("App", "RosterModel.swift"): ("live", "capabilities", "bots", "isLoaded")}


def in_app(parts: tuple[str, ...], text: str) -> bool:
    return parts[0] == "App"


def anywhere(parts: tuple[str, ...], text: str) -> bool:
    return True


def main_isolated(parts: tuple[str, ...], text: str) -> bool:
    return parts[0] == "App" or "@MainActor" in text


def view_file(parts: tuple[str, ...], text: str) -> bool:
    return parts[0] == "App" and bool(re.search(r":\s*(?:View|ViewModifier)\b", text))


def mac_shell(parts: tuple[str, ...], text: str) -> bool:
    return parts in SHELL_FILES


def row_file(parts: tuple[str, ...], text: str) -> bool:
    return parts in ROW_FILES


def chat_row_view_file(parts: tuple[str, ...], text: str) -> bool:
    return parts[:2] == ("App", "Chat") and "struct ChatRowView" in text


def hover_pill_file(parts: tuple[str, ...], text: str) -> bool:
    return parts[0] == "App" and "MacMessageHoverBar" in text


def bubble_file(parts: tuple[str, ...], text: str) -> bool:
    return parts[:2] == ("App", "Chat") and parts not in {("App", "Chat", "ChatRows.swift")}


def avatar_row_file(parts: tuple[str, ...], text: str) -> bool:
    return parts in AVATAR_ROW_FILES


def guarded_model(parts: tuple[str, ...], text: str) -> bool:
    return parts in GUARDED_WRITE_FIELDS


@dataclass(frozen=True)
class LineRule:
    rule: str
    pattern: re.Pattern[str]
    applies: Callable[[tuple[str, ...], str], bool]
    message: str
    in_view: bool = False
    in_view_type: bool = False
    skip: re.Pattern[str] | None = None
    keeps_strings: bool = False
    allowlisted: bool = False


def view_spans(src: Source) -> list[tuple[int, int]]:
    spans = []
    for open_index, close_index in _decls(src):
        line = src.lines[src.line_of(open_index) - 1]
        header = line[: open_index - src.starts[src.line_of(open_index) - 1] + 1]
        before = src.lines[src.line_of(open_index) - 2] if src.line_of(open_index) > 1 else ""
        is_decl = DECL.match(header) or header.lstrip().startswith(")")
        is_view = re.search(r"\bsome\s+View\b", header) or re.search(r"\bvar\s+body\b", header) or "@ViewBuilder" in before
        if is_decl and is_view:
            spans.append((open_index, close_index))
    return spans


LINE_RULES = (
    LineRule(
        "perf-body-parse",
        re.compile(
            r"\bMarkdownDocument\(\s*parsing:|\bParsedMarkdown\(\s*source:|\bAttributedString\(\s*markdown:"
            r"|\bViewerDocument\(\s*data:|\bDocumentText(?:Chunks\.split|\(\s*data:)"
        ),
        anywhere,
        "markdown or file text parsed inside a View body, on every body pass. Take a cached ParsedMarkdown: build it once in the "
        "model (ChatModel) or call ParsedMarkdown.cached(text), and pass it to MarkdownView(parsed:); a document viewer "
        "builds its ViewerDocument in Task.detached from a load method and holds the result in @State",
        in_view=True,
    ),
    LineRule(
        "perf-body-format",
        re.compile(r"\bCalendar\.current\b|\.formatted\(|\bDateFormatter\(\)|\bNumberFormatter\(\)|\bISO8601DateFormatter\(\)"),
        anywhere,
        "date or number formatting inside a View body, on every body pass. Format once in the model, or keep a "
        "static formatter and reuse it",
        in_view=True,
        keeps_strings=True,
    ),
    LineRule(
        "perf-redraw-per-call",
        re.compile(r"\.roundedIcon\(\s*points:"),
        in_app,
        "image redrawn on every call (and every view body). Round it once when it is stored in the cache "
        "(FaviconCache keeps the finished PlatformImage per size) and return that",
    ),
    LineRule(
        "perf-body-array-work",
        re.compile(r"\bForEach\([^\n]*\.reversed\(\)|\.onChange\(of:[^\n]*\.map\(\\\.id\)"),
        in_app,
        "array rebuilt in a View body on every pass (reversed rows, mapped ids). Compute it once when the rows change, "
        "in the model (ChatModel.rowsNewestFirst, ChatModel.rowIDs), and read the stored array",
        in_view=True,
    ),
    LineRule(
        "perf-table-in-text-bubble",
        re.compile(r"\bMarkdownView\(\s*parsed:"),
        row_file,
        "the whole document is rendered in one text bubble, so a table lands inside it. Build the bubbles from "
        "ParsedMarkdown.segments: MarkdownView(segment:) for each text segment and TableBubbleView for each table",
    ),
    LineRule(
        "perf-row-reads-model",
        re.compile(r"\bmodel\.(?:chatAccent|reactions|isFinding|findMatchIDs|findQuery|currentFindRowID|answeringConnections)\b"),
        row_file,
        "a chat row reads shared model state, so any change to it re-evaluates every visible row. Read it once in the "
        "list (ChatModel.rowContext) and pass it in the row's Equatable ChatRowContext",
    ),
    LineRule(
        "perf-hover-state-in-row-body",
        re.compile(r"\browHover\b|\bisHovering\b"),
        chat_row_view_file,
        "ChatRowView reads per-row hover state, so every pointer enter or exit re-runs chat.row.body. Only the small "
        "view that shows the hover affordance may read RowHoverState (MacMessageHoverBar); the row injects it with "
        ".environment(\\.rowHover, hover) and never reads it",
    ),
    LineRule(
        "perf-hover-pill-outside-tracker",
        re.compile(r"\.alignmentGuide\(|\.overlay\("),
        hover_pill_file,
        "the hover pill is placed by an overlay or alignmentGuide on its bubble, so it can sit outside the row's "
        "tracking rect (a bubble at the column edge): the pointer then leaves the tracker, mouseExited hides the pill "
        "under it and its buttons cannot be clicked. Resolve its frame with MessageChromePlacement.place(bubble:region:"
        "slot:bar:hasReaction:) inside MessageChromeLayout, whose region is the tracked row",
    ),
    LineRule(
        "perf-hover-tracker-per-bubble",
        re.compile(r"\bmacRowHover\(|\browHoverWiring\(|\bMacRowTracker\("),
        bubble_file,
        "a hover tracker per bubble: a message drawn as several bubbles (text, table, text) shares one RowHoverState "
        "per message, so moving between its bubbles or onto the pill must not exit. Wire hover once per message in "
        "ChatRows.swift (rowHoverWiring) and let the carrier bubble report its frame with .messageActions(side:placement:)",
    ),
    LineRule(
        "perf-observed-image-dictionary",
        re.compile(r"\bvar\s+\w+\s*:\s*\[\s*String\s*:\s*PlatformImage\s*\]"),
        in_app,
        "one dictionary of images on an observed type: every key finishing notifies every reader. Keep one @Observable "
        "slot per key (FaviconCache.Slot) so only the readers of that key update",
    ),
    LineRule(
        "perf-main-disk-read",
        re.compile(r"\bData\(\s*contentsOf:|\bString\(\s*contentsOf:|\bcontentsOfFile:"),
        main_isolated,
        "synchronous disk read on the main actor. Load off the main actor (CacheStore.loadDetached, or an actor / "
        "Task.detached loader) and apply the result on return",
    ),
    LineRule(
        "perf-main-json",
        re.compile(r"\bJSONEncoder\(\)|\bJSONDecoder\(\)|\bJSONSerialization\."),
        main_isolated,
        "JSON encode or decode on the main actor (and a new coder each call). Decode in the detached loader "
        "(CacheStore.loadDetached) and share one static coder",
    ),
    LineRule(
        "perf-queue-sync",
        re.compile(r"\bqueue\.sync\b"),
        anywhere,
        "queue.sync blocks the caller; from the main actor that is a main-thread stall. Use the async API "
        "(CacheStore.loadDetached: queue.async plus a continuation) and await it",
    ),
    LineRule(
        "perf-timeline-unlisted",
        re.compile(r"\bTimelineView\("),
        anywhere,
        f"TimelineView outside the allowlist. A ticking view re-renders its subtree on every tick: add the file to "
        f"apps/ios/{ALLOWLIST_NAME} with a reason, or drive the change from state instead",
        allowlisted=True,
    ),
    LineRule(
        "perf-timeline-interval",
        re.compile(r"\bTimelineView\(\s*\.animation\s*\)|\bTimelineView\(\s*\.animation\(\s*paused|"
                   r"\b(?:frameInterval|minimumInterval)\b[^\n]*\b1(?:\.0)?\s*/\s*(?:3[1-9]|[4-9]\d|\d{3,})\b"),
        anywhere,
        "unbounded or faster-than-30 fps animation schedule. Use TimelineView(.animation(minimumInterval: 1.0 / 30)) "
        "or slower (1.0 / 20 for small avatars), and pause it when idle",
    ),
    LineRule(
        "perf-avatar-row-slot",
        re.compile(r"\bBotAvatarView\("),
        avatar_row_file,
        "a list-row avatar animates its looping mood outside the window's shared slot. Pass sharesSlot: true "
        "(one row per window animates, the rest hold the static pose) or animated: false",
        skip=re.compile(r"\bsharesSlot:\s*true\b|\banimated:\s*false\b"),
    ),
    LineRule(
        "perf-hover-unlisted",
        re.compile(r"\.onContinuousHover\b"),
        anywhere,
        f"onContinuousHover outside the allowlist. Continuous tracking fires per mouse move for every row: use .onHover, "
        f"or add the file to apps/ios/{ALLOWLIST_NAME} with a reason",
        allowlisted=True,
    ),
    LineRule(
        "perf-animation-container",
        re.compile(r"\.animation\(.*\bvalue:"),
        mac_shell,
        "implicit .animation(_, value:) on the whole Mac shell animates and re-diffs every child. Animate the view "
        "that changes (withAnimation, or .animation on that leaf)",
    ),
    LineRule(
        "perf-monitor-per-view",
        re.compile(r"\bNSEvent\.addLocalMonitorForEvents\("),
        in_app,
        f"one NSEvent local monitor per view runs for every event and every bubble. Install one shared monitor "
        f"(MacMessageMenuHost owns it) and route events to the view that wants them; a single-instance, window-scoped "
        f"monitor goes in apps/ios/{ALLOWLIST_NAME} with a reason",
        allowlisted=True,
    ),
    LineRule(
        "perf-state-model-init",
        re.compile(rf"\bState\(\s*initialValue:\s*{OWNED_TYPE}\(|\bStateObject\(\s*wrappedValue:\s*{OWNED_TYPE}\("),
        in_app,
        "model built in a View init: every parent body builds and discards one. Declare "
        "`@State private var model = ...` (or take the model as a parameter) and load it in .task",
        in_view_type=True,
    ),
    LineRule(
        "perf-model-in-body",
        re.compile(r"\b\w+:\s*[A-Z]\w*(?:Model|Store)(?:\.\w+)?\("),
        view_file,
        "model constructed while building a view. Every parent body builds and discards one: hold it in "
        "`@State private var model = ...` on the screen that owns it and load it in .task",
        in_view=True,
    ),
    LineRule(
        "perf-unguarded-write",
        re.compile(rf"^\s*(?:self\.)?(?:{'|'.join(sorted({f for fields in GUARDED_WRITE_FIELDS.values() for f in fields}))})\s*=(?!=)"),
        guarded_model,
        "snapshot field of an @Observable model assigned without an equality guard: every assignment notifies every "
        "observer, even when the value is equal. Write it with assignIfChanged(\\.field, value) (PalRoster), which "
        "skips an equal value",
    ),
    LineRule(
        "perf-shadow-radius",
        re.compile(r"\.shadow\([^\n]*\bradius:\s*(?:2[4-9]|[3-9]\d|\d{3,})(?:\.\d+)?\b"),
        anywhere,
        f"blur radius of {SHADOW_MAX_RADIUS}+ on a large surface is re-rendered offscreen on every frame. Use a radius "
        f"under {SHADOW_MAX_RADIUS}, or a pre-rendered shadow asset",
    ),
)

FOREACH = "ForEach"
EAGER_STACKS = ("VStack",)
VIEW_TYPE_HEADER = re.compile(r"\b(?:struct|class|extension)\s+\w+[^{]*:[^{]*\b(?:View|ViewModifier)\b|\bextension\s+View\b")
GLASS_CALL = re.compile(r"\.(?:palGlass|glassEffect)\(")
OPAQUE_BACKGROUND = re.compile(r"\.background\(\s*(?!\.clear|Color\.clear|\.(?:ultraThin|thin|regular|thick)?Material|\.bar\b|in:)")


def block_regions(src: Source, name: str, skip_horizontal: bool = False) -> list[tuple[int, int]]:
    """(start, end) of each ``name(...) { ... }`` or ``name { ... }`` container."""
    regions = []
    for m in re.finditer(rf"(?<![A-Za-z0-9_]){name}\b", src.text):
        cursor = m.end()
        args = re.compile(r"\s*\(").match(src.text, cursor)
        if args:
            paren = args.end() - 1
            if paren not in src.close:
                continue
            if skip_horizontal and ".horizontal" in src.text[paren:src.close[paren]] and ".vertical" not in src.text[paren:src.close[paren]]:
                continue
            cursor = src.close[paren] + 1
        body = re.compile(r"\s*\{").match(src.text, cursor)
        if body and (body.end() - 1) in src.close:
            regions.append((m.start(), src.close[body.end() - 1]))
    return regions


def eager_stack(src: Source) -> Iterator[tuple[int, str]]:
    scrolls = block_regions(src, "ScrollView", skip_horizontal=True)
    if not scrolls:
        return
    for name in EAGER_STACKS:
        for start, end in block_regions(src, name):
            if not any(s < start and end <= e for s, e in scrolls):
                continue
            for fe_start, _, _ in src.calls(FOREACH):
                if start < fe_start < end and _direct_child(src, fe_start, start):
                    yield src.line_of(start), (f"{name} over a ForEach inside a ScrollView builds every row up front. "
                                               "Use LazyVStack (or LazyHStack) so only visible rows are built")
                    break


def _direct_child(src: Source, index: int, stack_start: int) -> bool:
    for opener in src.enclosing(index):
        if src.text[opener] != "{":
            continue
        header = src.lines[src.line_of(opener) - 1].strip()
        if re.match(r"(?:\}\s*)?(?:if|else|switch|case|guard)\b", header):
            continue
        return stack_start < opener and src.line_of(opener) >= src.line_of(stack_start) and bool(
            re.search(r"\b(?:VStack|HStack)\b", header)
        )
    return False


def geometry_per_row(src: Source) -> Iterator[tuple[int, str]]:
    rows = [(s, e) for s, _, e in src.calls(FOREACH)]
    for m in re.finditer(r"\.onGeometryChange\(", src.text):
        if any(s < m.start() < e for s, e in rows):
            yield src.line_of(m.start()), ("onGeometryChange on every row of a ForEach measures each row on every layout. "
                                           "Measure once on the container (one onGeometryChange on the scroll content), "
                                           "or use scrollPosition / scrollTargetLayout")


def glass_over_fill(src: Source) -> Iterator[tuple[int, str]]:
    for m in GLASS_CALL.finditer(src.text):
        open_index = m.end() - 1
        args = src.text[open_index:src.close.get(open_index, open_index) + 1]
        if "interactive: false" in args:
            continue
        line = src.line_of(m.start())
        chain = [src.lines[line - 1][: m.start() - src.starts[line - 1]]]
        for prior in reversed(src.lines[max(0, line - 13): line - 1]):
            chain.append(prior)
            if not prior.strip().startswith("."):
                break
        if OPAQUE_BACKGROUND.search("\n".join(chain)):
            yield line, ("interactive glass over an opaque .background(...) fill: the glass samples the fill on every "
                         "frame. Drop the fill and let the glass be the surface, or pass interactive: false")


def monitor_unpaired(src: Source) -> Iterator[tuple[int, str]]:
    if "removeMonitor" in src.text:
        return
    for m in re.finditer(r"\bNSEvent\.addLocalMonitorForEvents\(", src.text):
        yield src.line_of(m.start()), ("NSEvent monitor added with no removal in the file: every monitor needs a paired "
                                       "NSEvent.removeMonitor (on teardown or when the last user leaves)")


BINDING_DECL = re.compile(r"@(?:Binding|AppStorage|SceneStorage)\b(?:\([^)]*\))?\s+(?:private\s+)?var\s+(\w+)")
ON_CHANGED = re.compile(r"\s*\.onChanged\s*\{")


def drag_writes_binding(src: Source) -> Iterator[tuple[int, str]]:
    names = set(BINDING_DECL.findall(src.text))
    if not names:
        return
    write = re.compile(rf"(?<![\w.])(?:self\.)?({'|'.join(sorted(names))})\s*[-+*/]?=(?!=)")
    for _, _, end in src.calls("DragGesture"):
        handler = ON_CHANGED.match(src.text, end + 1)
        if not handler:
            continue
        opener = handler.end() - 1
        for m in write.finditer(src.text, opener, src.close.get(opener, opener)):
            yield src.line_of(m.start()), (f"drag tick writes {m.group(1)}, a @Binding or stored property owned by an ancestor: every tick "
                                           "re-evaluates the ancestor's body. Keep the live value in a small model or local @State "
                                           "(PalDesign DragWidth) and write the stored value once in .onEnded")


PUBLISH_FUNC = re.compile(r"\bfunc\s+(publish|apply)\w*\s*\(")
LOCAL_BINDING = re.compile(r"^[ \t]*(?:let|var)\s+(\w+)\b[^=\n]*=(?!=)", re.MULTILINE)


def dropped_value(src: Source) -> Iterator[tuple[int, str]]:
    for m in PUBLISH_FUNC.finditer(src.text):
        paren = m.end() - 1
        header = re.compile(r"[^{};]*\{").match(src.text, src.close.get(paren, -2) + 1)
        if not header or (header.end() - 1) not in src.close:
            continue
        start, end = header.end(), src.close[header.end() - 1]
        body = src.text[start:end]
        if m.group(1) == "publish" and "assignIfChanged(" not in body:
            yield src.line_of(m.start()), ("publish never assigns what it builds: the model keeps showing the old "
                                           "value. Write the result with assignIfChanged(\\.field, value)")
        for local in LOCAL_BINDING.finditer(body):
            if len(re.findall(rf"\b{local.group(1)}\b", body)) == 1:
                yield src.line_of(start + local.start(1)), (f"`{local.group(1)}` is computed and never used: the work "
                                                            "is dropped. Assign it with assignIfChanged(\\.field, value) or delete it")


def open_ungated(src: Source) -> Iterator[tuple[int, str]]:
    for m in re.finditer(r"\bTimelinePacer\.consume\(", src.text):
        paren = m.end() - 1
        if paren in src.close and ".admit(" not in src.text[paren:src.close[paren]]:
            yield src.line_of(m.start()), ("timeline snapshots reach the chat model without ChatOpenGate: the cached "
                                           "timeline paints as live rows and the live history then corrects it. Route "
                                           "every snapshot through openGate.admit(_:) and apply only what it returns")


def selection_over_markdown(src: Source) -> Iterator[tuple[int, str]]:
    for m in re.finditer(r"\.(?:bubbleTextSelection|textSelection)\(", src.text):
        opener = next((o for o in src.enclosing(m.start()) if src.text[o] == "{"), None)
        if opener is not None and re.search(r"\bMarkdownView\(|\bbubbleContent\b", src.text[opener:src.close[opener]]):
            yield src.line_of(m.start()), ("text selection applied over a multi-block markdown view: every block is its own "
                                           "Text, so a drag stops at each paragraph. Let MarkdownView own selection "
                                           "(SelectableMarkdownText selects the whole bubble on Mac)")


BLOCK_RULES: tuple[tuple[str, Callable[[tuple[str, ...], str], bool], Callable[[Source], Iterator[tuple[int, str]]]], ...] = (
    ("perf-eager-stack", in_app, eager_stack),
    ("perf-geometry-per-row", in_app, geometry_per_row),
    ("perf-glass-over-fill", anywhere, glass_over_fill),
    ("perf-monitor-unpaired", in_app, monitor_unpaired),
    ("perf-dropped-value", guarded_model, dropped_value),
    ("perf-drag-writes-binding", in_app, drag_writes_binding),
    ("perf-open-ungated", in_app, open_ungated),
    ("perf-selection-island", row_file, selection_over_markdown),
)


@dataclass(frozen=True)
class Allowlist:
    entries: frozenset[tuple[str, str]]

    def allows(self, rule: str, rel: Path) -> bool:
        return (rule, rel.as_posix()) in self.entries


def load_allowlist(path: Path) -> Allowlist:
    if not path.is_file():
        return Allowlist(frozenset())
    entries = set()
    for entry in json.loads(path.read_text(encoding="utf-8-sig")):
        rule, file, reason = entry.get("rule"), entry.get("file"), str(entry.get("reason", "")).strip()
        if rule not in ALLOWLISTED_RULES or not file or not reason:
            raise SystemExit(f"{path.name}: every entry needs a rule in {ALLOWLISTED_RULES}, a file and a reason: {entry}")
        entries.add((rule, file))
    return Allowlist(frozenset(entries))


def _in_view_type(src: Source, index: int) -> bool:
    for opener in src.enclosing(index):
        header = src.text[src.starts[src.line_of(opener) - 1]:opener]
        if re.search(r"\b(?:struct|class|enum|extension)\s", header):
            return bool(VIEW_TYPE_HEADER.search(header + " {"))
    return False


def violations(rel: Path, source: str, allowlist: Allowlist | None = None) -> list[Finding]:
    allowlist = allowlist or Allowlist(frozenset())
    src = Source(source)
    found: list[Finding] = []
    views = view_spans(src)

    def add(rule: str, line: int, message: str) -> None:
        text = src.original[line - 1]
        if OPT_OUT not in text:
            found.append(Finding(rule, rel.as_posix(), line, text.strip(), message))

    for lr in LINE_RULES:
        if not lr.applies(rel.parts, source):
            continue
        if lr.allowlisted and allowlist.allows(lr.rule, rel):
            continue
        for i in range(len(src.lines)):
            code = src.lines[i] if lr.keeps_strings else src.plain[i]
            m = lr.pattern.search(code)
            if not m or (lr.skip and lr.skip.search(code)):
                continue
            at = src.starts[i] + m.start()
            if lr.in_view and not any(s < at < e for s, e in views):
                continue
            if lr.in_view_type and not _in_view_type(src, at):
                continue
            add(lr.rule, i + 1, lr.message)
    for rule, applies, fn in BLOCK_RULES:
        if applies(rel.parts, source):
            for line, message in fn(src):
                add(rule, line, message)
    return found


def scan(root: Path, allowlist: Allowlist | None = None) -> list[Finding]:
    allowlist = allowlist if allowlist is not None else load_allowlist(root / ALLOWLIST_NAME)
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP.intersection(rel.parts):
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"), allowlist)
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    baseline_path = root / BASELINE_NAME
    found = scan(root)
    if "--write-baseline" in argv:
        write_baseline(baseline_path, found)
        print(f"wrote {len(found)} entries to {baseline_path}")
        return 0
    baseline = Counter() if "--no-baseline" in argv else load_baseline(baseline_path)
    fresh, stale = new_findings(found, baseline)
    for finding in fresh:
        print(finding.render())
    if fresh:
        print(f"\n{len(fresh)} Mac performance finding(s) (rules: apps/ios/AGENTS.md, Performance). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line. Existing findings live in {BASELINE_NAME}; '
              "never add new ones there.")
        return 1
    if stale:
        print(f"swift-perf: ok; {stale} baseline entr{'y is' if stale == 1 else 'ies are'} fixed "
              "(run --write-baseline to drop them)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
