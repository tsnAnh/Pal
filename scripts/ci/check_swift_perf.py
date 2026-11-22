#!/usr/bin/env python3
"""Fail when Pal Swift code repeats a Mac performance mistake (table in apps/ios/AGENTS.md, "Performance").

Same mechanism as ``check_swift_glass.py`` (text only, no Swift toolchain; its bracket-aware
``Source`` scanner and baseline helpers are reused). Findings already on main sit in
``apps/ios/.perf-lint-baseline.json`` (matched by rule, file and line text); only a NEW finding
fails, and a fix that removes one leaves a stale entry that is reported and harmless
(``--write-baseline`` rewrites the file). Files that may use ``TimelineView``, ``onContinuousHover``, a
single-instance ``NSEvent`` monitor or an observed still image are listed with a reason in ``apps/ios/.perf-lint-allowlist.json``. A justified
exception carries ``perf-lint: ok`` on the flagged line.

Rules: perf-body-parse, perf-body-format, perf-redraw-per-call, perf-main-disk-read, perf-main-json,
perf-queue-sync, perf-timeline-unlisted, perf-timeline-interval, perf-hover-unlisted,
perf-animation-container, perf-eager-stack, perf-monitor-per-view, perf-geometry-per-row,
perf-state-model-init, perf-model-in-body, perf-shadow-radius, perf-glass-over-fill, perf-unguarded-write,
perf-body-array-work, perf-row-reads-model, perf-observed-image-dictionary, perf-monitor-unpaired, perf-dropped-value,
perf-avatar-row-slot, perf-drag-writes-binding, perf-open-ungated, perf-hover-state-in-row-body, perf-selection-island,
perf-table-in-text-bubble, perf-hover-pill-outside-tracker, perf-hover-tracker-per-bubble, perf-screen-reads-draft,
perf-screen-reads-stream, perf-shell-layout-probe, perf-observed-frame-image, perf-frame-cpu-draw, perf-unguarded-scroll-write,
perf-foreach-regroup, perf-textkit-outside-layout, perf-row-openurl-closure, perf-markdown-foreach-not-equatable,
perf-path-description-key, perf-timestamp-uncached, perf-hover-bar-unconditional, perf-textview-scroll,
perf-test-shared-counter (test files).

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
TEST_DIR = "Tests"
ALLOWLISTED_RULES = ("perf-timeline-unlisted", "perf-hover-unlisted", "perf-monitor-per-view", "perf-observed-frame-image")
SHADOW_MAX_RADIUS = 24
OWNED_TYPE = r"[A-Z]\w*(?:Model|Store|Hub|Conversation|Controller)(?:\.\w+)?"
SHELL_FILES = {("App", "Mac", "MacShell.swift")}
ROW_FILES = {("App", "Chat", "ChatRows.swift"), ("App", "Chat", "AssistantBubble.swift")}
AVATAR_ROW_FILES = {("App", "Mac", "MacSidebar.swift"), ("App", "HomeView.swift"), ("App", "Rooms", "RoomRows.swift")}
CHAT_MODEL_GUARDED = (
    "rows", "rowsNewestFirst", "rowIDs", "connection", "isRunning", "workingStatus", "hasPendingClarify", "hasPendingPrompt",
    "olderHistory", "findMatches", "findPosition",
)
GUARDED_WRITE_FIELDS = {
    ("App", "RosterModel.swift"): ("live", "capabilities", "bots", "isLoaded"),
    ("App", "ChatModel.swift"): CHAT_MODEL_GUARDED,
    ("App", "ChatModel+StreamingPatch.swift"): CHAT_MODEL_GUARDED,
}


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


def in_files(*files: tuple[str, ...]) -> Callable[[tuple[str, ...], str], bool]:
    return lambda parts, text: parts in files


def app_except(home: tuple[str, ...]) -> Callable[[tuple[str, ...], str], bool]:
    return lambda parts, text: parts[0] == "App" and parts != home


def observable_app_file(parts: tuple[str, ...], text: str) -> bool:
    return parts[0] == "App" and "@Observable" in text


def under(*prefix: str) -> Callable[[tuple[str, ...], str], bool]:
    return lambda parts, text: parts[: len(prefix)] == prefix


CHAT_SCREEN = in_files(("App", "ChatView.swift"))
SHELL_LAYOUT = in_files(("App", "Mac", "MacShellLayout.swift"))
SCROLL_CONTROLLER = in_files(("App", "Chat", "ChatScrollController.swift"))
SELECTABLE_LAYOUT_HOME = ("App", "Chat", "SelectableTextLayout.swift")
TIMESTAMP_HOME = ("App", "Chat", "ChatTimestampCache.swift")
PAL_DESIGN_SOURCES = under("Packages", "PalDesign", "Sources")
STREAMING_MODEL_FIELDS = (
    "rows|rowsNewestFirst|olderHistory|isRunning|workingStatus|hasPendingClarify|hasPendingPrompt|connection|isCatchingUp|isFinding"
    "|isOpening|currentFindRowID|findMatches|findPosition|rowContextSource"
)


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
        "perf-screen-reads-draft",
        re.compile(r"(?<![\w$.])draft\b(?!\s*(?::(?!:)|=(?!=)))"),
        CHAT_SCREEN,
        "the chat screen reads the composer draft by value, so every keystroke re-runs ChatView.body and everything under it. "
        "Hand the draft down only as $draft (ChatBottomBar owns it); a reader of the live text uses "
        ".reportsComposerDraft(draft) on the composer, which fills ComposerActivity.draft and invalidates no ancestor",
        skip=re.compile(r"\bvar\s+draft\b"),
    ),
    LineRule(
        "perf-screen-reads-stream",
        re.compile(rf"\bmodel\.(?:{STREAMING_MODEL_FIELDS})\b|\bscroll\.(?:wantsOlder|showsJumpButton|unseen|mode)\b"),
        CHAT_SCREEN,
        "the chat screen reads state that changes with every streamed token or scroll tick, so ChatView.body re-runs per update. "
        "Read it in the narrow view or modifier that needs it (ChatTranscriptList, ChatRowsSync, ChatOlderPaging, "
        "ChatScreenAccessibility in ChatTranscriptReaders) and keep ChatView to stable references",
    ),
    LineRule(
        "perf-observed-frame-image",
        re.compile(r"^\s*(?:(?:private|fileprivate|public)(?:\(set\))?\s+)*var\s+\w+\s*:\s*(?:CGImage|CVPixelBuffer|CVImageBuffer)\??"),
        observable_app_file,
        "a decoded frame (CGImage or pixel buffer) held in a property the @Observable macro tracks: every frame invalidates "
        "each view that reads the model. Submit frames to a plain-class sink the surface drains on its display link and shows "
        "as layer.contents (ComputerFrameSink, ComputerFrameDelivery), or mark the property @ObservationIgnored",
        skip=re.compile(r"(?:CGImage|CVPixelBuffer|CVImageBuffer)\??\s*\{"),
        allowlisted=True,
    ),
    LineRule(
        "perf-frame-cpu-draw",
        re.compile(r"\b(?:context|ctx|cgContext)\.draw\(\s*\w*[iI]mage\b"),
        in_app,
        "an image redrawn with CoreGraphics on every update (draw(_:) per frame). Hand the CGImage to the layer "
        "(layer.contents through ComputerFrameDelivery) so the compositor scales and presents it",
    ),
    LineRule(
        "perf-unguarded-scroll-write",
        re.compile(r"^\s*(?:self\.)?position\.scrollTo\(\s*(?:y:|edge:)"),
        SCROLL_CONTROLLER,
        "ScrollPosition written without an equality guard: ChatScrollController.position is observed, so every write "
        "re-runs the list even when the position is unchanged. Write through write { $0.scrollTo(...) }, which skips an equal position",
    ),
    LineRule(
        "perf-foreach-regroup",
        re.compile(r"\bForEach\(\s*(?:Array\(\s*)?[A-Z]\w*\.\w+\(\s*(?:self\.)?model\."),
        in_app,
        "ForEach data rebuilt from the model on every body pass (grouped, sorted or bucketed by date). Build the flat items "
        "once when the model changes and cache them on the model keyed by a version (LibraryModel.macItems, MacLibraryItems), "
        "then ForEach over the stored items",
    ),
    LineRule(
        "perf-textkit-outside-layout",
        re.compile(r"\bNSLayoutManager\(|\bNSTextStorage\(|\bNSTextContainer\(|\.ensureLayout\(|\.usedRect\("),
        app_except(SELECTABLE_LAYOUT_HOME),
        "TextKit layout objects or a main-actor measure outside SelectableTextLayout: a layout stack per view or a measure per "
        "row on the main actor is what stalled chat scrolling. Size text through SelectableSizeCache and "
        "SelectableTextLayout.Session, prefetched off the main actor by SelectableTextPrefetcher",
    ),
    LineRule(
        "perf-row-openurl-closure",
        re.compile(r"\.environment\(\\\.openURL,\s*OpenURLAction\b"),
        row_file,
        "a chat row builds a new OpenURLAction on every body pass, so the environment value changes and every reader "
        "(each SelectableMarkdownText) is invalidated. Keep one router per row (FileLinkRouter in AssistantBubble: @State, "
        "returns one stable OpenURLAction) and update its data instead",
    ),
    LineRule(
        "perf-path-description-key",
        re.compile(r"\bpath\.description\b"),
        lambda parts, text: in_app(parts, text) or PAL_DESIGN_SOURCES(parts, text),
        "a cache key built from CGPath.description: the string is thousands of characters and is rebuilt on every lookup. "
        "Key on a Hashable struct of the inputs (SolidGeometry.Key, SolidEyeKey)",
        keeps_strings=True,
    ),
    LineRule(
        "perf-timestamp-uncached",
        re.compile(r"\bChatTimestamp\.label\("),
        app_except(TIMESTAMP_HOME),
        "a chat timestamp formatted per row on every body pass. Read ChatTimestampCache.shared.label(for:), which memoizes "
        "per date and expires on locale, time zone and day change",
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
        "model built in a View init: every parent body builds and discards one. Declare `@LazyState private var model: Model`, "
        "assign `_model = LazyState { Model(...) }` in init (App/Platform/LazyState.swift builds it once), or take the model "
        "as a parameter, and load it in .task",
        in_view_type=True,
    ),
    LineRule(
        "perf-model-in-body",
        re.compile(r"\b\w+:\s*[A-Z]\w*(?:Model|Store)(?:\.\w+)?\("),
        view_file,
        "model constructed while building a view. Every parent body builds and discards one: build it inside "
        "ModelHost { Model(...) } content: { model in ... } or hold it in @LazyState on the screen that owns it "
        "(App/Platform/LazyState.swift), and load it in .task",
        in_view=True,
    ),
    *(
        LineRule(
            "perf-unguarded-write",
            re.compile(rf"^\s*(?:self\.)?(?:{'|'.join(sorted(fields))})\s*=(?!=)"),
            lambda parts, text, guarded=guarded: parts == guarded,
            "snapshot field of an @Observable model assigned without an equality guard: every assignment notifies every "
            "observer, even when the value is equal. Write it with assignIfChanged(\\.field, value) (PalRoster), which "
            "skips an equal value",
        )
        for guarded, fields in GUARDED_WRITE_FIELDS.items()
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


SUBVIEW_PROBE = re.compile(r"\.sizeThatFits\(")
UNCONSTRAINED_PROPOSAL = re.compile(r"\(\s*(?:ProposedViewSize)?\.(?:unspecified|zero|infinity)\s*\)")


def shell_layout_probe(src: Source) -> Iterator[tuple[int, str]]:
    for m in SUBVIEW_PROBE.finditer(src.text):
        paren = m.end() - 1
        unconstrained = UNCONSTRAINED_PROPOSAL.match(src.text, paren)
        measuring = any(
            re.search(r"\bfunc\s+sizeThatFits\b", src.text[src.starts[src.line_of(o) - 1]:o]) for o in src.enclosing(m.start())
        )
        if unconstrained or measuring:
            yield src.line_of(m.start()), ("the Mac shell layout probes subviews with an unconstrained proposal or measures them "
                                           "inside sizeThatFits: every window resize frame re-measures the whole content tree. "
                                           "sizeThatFits answers from the proposal alone; placeSubviews measures only the sidebar, "
                                           "at a concrete height: subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height))")


EQUATABLE_MARKDOWN_VIEW = re.compile(r"\bMarkdown(?:Item|Block|Run)View\(")
APPLIES_EQUATABLE = re.compile(r"\s*\.equatable\(\)")


def markdown_foreach_not_equatable(src: Source) -> Iterator[tuple[int, str]]:
    for start, _, end in src.calls(FOREACH):
        for m in EQUATABLE_MARKDOWN_VIEW.finditer(src.text, start, end):
            paren = m.end() - 1
            if paren in src.close and not APPLIES_EQUATABLE.match(src.text, src.close[paren] + 1):
                yield src.line_of(m.start()), ("a markdown item, block or run view built in a ForEach without .equatable(): every "
                                               "streamed delta re-evaluates every unchanged block. These views are Equatable; "
                                               "apply .equatable() to each one built in the ForEach")


def hover_bar_unconditional(src: Source) -> Iterator[tuple[int, str]]:
    for m in re.finditer(r"\bMacMessageHoverBar\(", src.text):
        headers = (src.text[src.starts[src.line_of(o) - 1]:o] for o in src.enclosing(m.start()) if src.text[o] == "{")
        if not any(re.search(r"\bif\b", header) for header in headers):
            yield src.line_of(m.start()), ("the hover bar is built for every row while hidden: each row pays for a "
                                           "GlassEffectContainer and its buttons. Build MacMessageHoverBar only while the row is "
                                           "hovered, focused or showing its menu (the barBuilt gate in MacMessageChrome)")


TEXT_VIEW_SUBCLASS = re.compile(r"\bclass\s+\w+\s*:\s*NSTextView\b")
SCROLL_OVERRIDE = re.compile(r"\boverride\s+func\s+scroll\s*\(\s*_\s+\w+\s*:\s*NSPoint\s*\)")


def textview_scrolls_transcript(src: Source) -> Iterator[tuple[int, str]]:
    for m in TEXT_VIEW_SUBCLASS.finditer(src.text):
        opener = src.text.find("{", m.end())
        if opener in src.close and not SCROLL_OVERRIDE.search(src.text, opener, src.close[opener]):
            yield src.line_of(m.start()), ("an NSTextView subclass without override func scroll(_ point: NSPoint): while it lays out, "
                                           "AppKit calls scroll(_:) on the text view, which scrolls the enclosing transcript scroll view. "
                                           "The transcript jumps, SwiftUI realizes extra rows around the jump, and the chat open pays "
                                           "for them. Override it and scroll only while the view is the first responder")


BLOCK_RULES: tuple[tuple[str, Callable[[tuple[str, ...], str], bool], Callable[[Source], Iterator[tuple[int, str]]]], ...] = (
    ("perf-eager-stack", in_app, eager_stack),
    ("perf-geometry-per-row", in_app, geometry_per_row),
    ("perf-glass-over-fill", anywhere, glass_over_fill),
    ("perf-monitor-unpaired", in_app, monitor_unpaired),
    ("perf-dropped-value", guarded_model, dropped_value),
    ("perf-drag-writes-binding", in_app, drag_writes_binding),
    ("perf-open-ungated", in_app, open_ungated),
    ("perf-selection-island", row_file, selection_over_markdown),
    ("perf-shell-layout-probe", SHELL_LAYOUT, shell_layout_probe),
    ("perf-markdown-foreach-not-equatable", in_app, markdown_foreach_not_equatable),
    ("perf-hover-bar-unconditional", in_app, hover_bar_unconditional),
    ("perf-textview-scroll", in_app, textview_scrolls_transcript),
)

TEST_LINE_RULES = (
    LineRule(
        "perf-test-shared-counter",
        re.compile(r"\b[A-Z]\w*\.(?:cache|shared)\.(?:statistics|hits|misses|buildCount|callCount)\b"),
        anywhere,
        "a test reads hit or build counters of a process-wide cache. Test suites run in parallel and share it, so the "
        "delta races and the test flakes. Assert on a cache the test owns (SolidCache(capacity:)) or on key equality",
    ),
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


def violations(
    rel: Path,
    source: str,
    allowlist: Allowlist | None = None,
    line_rules: tuple[LineRule, ...] = LINE_RULES,
    block_rules: tuple[tuple[str, Callable[[tuple[str, ...], str], bool], Callable[[Source], Iterator[tuple[int, str]]]], ...] = BLOCK_RULES,
) -> list[Finding]:
    allowlist = allowlist or Allowlist(frozenset())
    src = Source(source)
    found: list[Finding] = []
    views = view_spans(src)

    def add(rule: str, line: int, message: str) -> None:
        text = src.original[line - 1]
        if OPT_OUT not in text:
            found.append(Finding(rule, rel.as_posix(), line, text.strip(), message))

    for lr in line_rules:
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
    for rule, applies, fn in block_rules:
        if applies(rel.parts, source):
            for line, message in fn(src):
                add(rule, line, message)
    return found


def scan(root: Path, allowlist: Allowlist | None = None) -> list[Finding]:
    allowlist = allowlist if allowlist is not None else load_allowlist(root / ALLOWLIST_NAME)
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if TEST_DIR in rel.parts and not (SKIP - {TEST_DIR}).intersection(rel.parts):
            found += violations(rel, path.read_text(encoding="utf-8-sig"), allowlist, TEST_LINE_RULES, ())
            continue
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
