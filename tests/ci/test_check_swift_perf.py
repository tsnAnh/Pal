"""scripts/ci/check_swift_perf.py: Pal Swift code does not repeat the Mac performance mistakes."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_swift_perf.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_swift_perf as csp

SCREEN = "App/View.swift"
MAC_SHELL = "App/Mac/MacShell.swift"
DESIGN = "Packages/PalDesign/Sources/PalDesign/Part.swift"
CACHE = "Packages/PalKit/Sources/PalProtocol/Cache/CacheStore.swift"
ROSTER = "App/RosterModel.swift"
ROWS = "App/Chat/ChatRows.swift"
CHAT_MODEL = "App/ChatModel.swift"
CHAT_VIEW = "App/ChatView.swift"
SHELL_LAYOUT = "App/Mac/MacShellLayout.swift"
SCROLL_CONTROLLER = "App/Chat/ChatScrollController.swift"
MARKDOWN_VIEW = "App/Chat/MarkdownView.swift"
SELECTABLE_TEXT = "App/Chat/SelectableMarkdownText.swift"
SELECTABLE_LAYOUT = "App/Chat/SelectableTextLayout.swift"
TIMESTAMP_CACHE = "App/Chat/ChatTimestampCache.swift"
ASSISTANT_BUBBLE = "App/Chat/AssistantBubble.swift"
SOLID = "Packages/PalDesign/Sources/PalDesign/Solid/SolidGeometry.swift"
MESSAGE_ACTIONS = "App/Mac/MacMessageActions.swift"


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, body in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return tmp_path


def _rules(tmp_path: Path, rel: str, body: str) -> list[str]:
    return [f.rule for f in csp.scan(_tree(tmp_path, {rel: body}))]


CASES = [
    ("perf-body-parse", SCREEN,
     "struct Row: View {\n    var body: some View {\n        MarkdownView(document: MarkdownDocument(parsing: text))\n    }\n}\n",
     "struct Row: View {\n    var body: some View {\n        MarkdownView(parsed: ParsedMarkdown.cached(text))\n    }\n}\n"),
    ("perf-body-parse", SCREEN,
     "struct Row: View {\n    @ViewBuilder\n    private var content: some View {\n        let md = document ?? MarkdownDocument(parsing: text)\n        Text(\"x\")\n    }\n}\n",
     "struct Model {\n    init(text: String) {\n        parsed = ParsedMarkdown(source: text, document: MarkdownDocument(parsing: text))\n    }\n}\n"),
    ("perf-body-parse", SCREEN,
     "struct Row: View {\n    var body: some View {\n        Text(try! AttributedString(markdown: text))\n    }\n}\n",
     "struct Row: View {\n    let text: AttributedString\n    var body: some View { Text(text) }\n}\n"),
    ("perf-body-parse", "App/Chat/ImageViewer/MacDocumentViewer.swift",
     "struct Page: View {\n    var body: some View {\n        Page(document: ViewerDocument(data: data, kind: kind, file: file, chatFiles: files))\n    }\n}\n",
     "struct Stage: View {\n    @State var phase = 0\n    var body: some View { Text(\"x\") }\n    private func load() async {\n        let document = await Task.detached { ViewerDocument(data: data, kind: kind, file: file, chatFiles: files) }.value\n    }\n}\n"),
    ("perf-body-format", SCREEN,
     "struct Row: View {\n    var body: some View {\n        Text(\"Next run \\(next.formatted(date: .abbreviated, time: .shortened))\")\n    }\n}\n",
     "struct Row: View {\n    let label: String\n    var body: some View { Text(label) }\n}\nfunc label(_ d: Date) -> String { d.formatted() }\n"),
    ("perf-body-format", SCREEN,
     "struct Row: View {\n    var body: some View {\n        let day = Calendar.current.startOfDay(for: date)\n        Text(\"\\(day)\")\n    }\n}\n",
     "struct Row: View {\n    let day: Date\n    var body: some View { Text(\"\\(day)\") }\n}\n"),
    ("perf-avatar-row-slot", "App/Mac/MacSidebar.swift",
     "struct R: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: 24, mood: mood)\n    }\n}\n",
     "struct R: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: 24, mood: mood, sharesSlot: true)\n    }\n}\n"),
    ("perf-table-in-text-bubble", ROWS,
     "ChatBubble(style: agent) {\n    MarkdownView(parsed: parsed, highlight: h, isCurrentMatch: false)\n}\n",
     "ChatBubble(style: agent) {\n    MarkdownView(segment: segment, wholeBubbleSelection: true, highlight: h, isCurrentMatch: false)\n}\n"),
    ("perf-selection-island", ROWS,
     "ChatBubble(style: agent) {\n    bubbleContent.bubbleTextSelection()\n}\n",
     "ChatBubble(style: agent) {\n    bubbleContent\n}\n"),
    ("perf-redraw-per-call", SCREEN,
     "if let image = images[host] { return image.roundedIcon(points: pointSize) }\n",
     "if let image = rounded[host] { return image }\n"),
    ("perf-main-disk-read", SCREEN, "let text = try? String(contentsOf: url, encoding: .utf8)\n", "let text = await loader.text(at: url)\n"),
    ("perf-main-disk-read", SCREEN, "let data = try? Data(contentsOf: url)\n", "let data = await loader.data(at: url)\n"),
    ("perf-main-disk-read", DESIGN, "@MainActor\nfinal class M {\n    func f() { _ = try? Data(contentsOf: url) }\n}\n",
     "final class M {\n    func f() { _ = try? Data(contentsOf: url) }\n}\n"),
    ("perf-main-json", SCREEN, "guard let data = try? JSONEncoder().encode(value) else { return nil }\n",
     "guard let data = try? Self.encoder.encode(value) else { return nil }\n"),
    ("perf-main-json", SCREEN, "return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]\n", "return decoded\n"),
    ("perf-queue-sync", CACHE,
     "public func load() -> Value? {\n    queue.sync { read() }\n}\n",
     "public func load() async -> Value? {\n    await withCheckedContinuation { c in queue.async { c.resume(returning: read()) } }\n}\n"),
    ("perf-timeline-unlisted", SCREEN, "TimelineView(.periodic(from: .now, by: 30)) { _ in Text(\"x\") }\n", "Text(\"x\")\n"),
    ("perf-timeline-interval", DESIGN, "TimelineView(.animation) { _ in Text(\"x\") }\n", "Text(\"x\")\n"),
    ("perf-timeline-interval", DESIGN, "frameInterval: reduceMotion ? 1.0 / 20 : 1.0 / 60,\n", "frameInterval: reduceMotion ? 1.0 / 20 : 1.0 / 30,\n"),
    ("perf-hover-unlisted", DESIGN, "content.background { Color.clear.onContinuousHover { phase in look(phase) } }\n",
     "content.onHover { inside in look(inside) }\n"),
    ("perf-animation-container", MAC_SHELL, "HStack { sidebar }\n    .animation(.snappy(duration: 0.22), value: shell.isCompact)\n",
     "HStack { sidebar }\n    .onChange(of: shell.isCompact) { withAnimation(.snappy) { apply() } }\n"),
    ("perf-eager-stack", SCREEN,
     "ScrollView {\n    VStack(spacing: 3) {\n        ForEach(roster.bots) { bot in Row(bot) }\n    }\n}\n",
     "ScrollView {\n    LazyVStack(spacing: 3) {\n        ForEach(roster.bots) { bot in Row(bot) }\n    }\n}\n"),
    ("perf-monitor-per-view", SCREEN, "monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { $0 }\n",
     "MessageMenuHost.shared.register(self)\n"),
    ("perf-geometry-per-row", SCREEN,
     "LazyVStack {\n    ForEach(rows) { row in\n        RowView(row)\n            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { moved(row.id, $0) }\n    }\n}\n",
     "LazyVStack {\n    ForEach(rows) { row in RowView(row) }\n}\n.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }\n"),
    ("perf-body-array-work", SCREEN,
     "struct Chat: View {\n    var chat: some View {\n        ForEach(model.rows.reversed()) { row in Row(row) }\n    }\n}\n",
     "struct Chat: View {\n    var chat: some View {\n        ForEach(model.rowsNewestFirst) { row in Row(row) }\n    }\n}\n"),
    ("perf-body-array-work", SCREEN,
     "struct Chat: View {\n    var chat: some View {\n        content\n            .onChange(of: model.rows.map(\\.id), initial: true) { _, ids in seen(ids) }\n    }\n}\n",
     "struct Chat: View {\n    var chat: some View {\n        content\n            .onChange(of: model.rowIDs, initial: true) { _, ids in seen(ids) }\n    }\n}\n"),
    ("perf-row-reads-model", ROWS, "ink: BubblePalette.ink(accent: model.chatAccent)\n", "ink: BubblePalette.ink(accent: context.accent)\n"),
    ("perf-row-reads-model", ROWS, "reaction: model.reactions[id],\n", "reaction: context.reaction,\n"),
    ("perf-hover-state-in-row-body", ROWS,
     "struct ChatRowView: View {\n    @Environment(\\.rowHover) private var hover\n    var body: some View { Text(hover?.isHovering == true ? \"a\" : \"b\") }\n}\n",
     "struct ChatRowView: View {\n    var body: some View { content.rowHoverWiring(actions) }\n}\n"),
    ("perf-hover-pill-outside-tracker", "App/Mac/MacMessageActions.swift",
     "content.overlay(alignment: .trailing) {\n    MacMessageHoverBar(actions: actions)\n        .alignmentGuide(.trailing) { $0[.leading] - messageBarGap }\n}\nstruct MacMessageHoverBar: View {}\n",
     "content.overlayPreferenceValue(MessageCarrierKey.self) { carrier in MacMessageChrome(carrier: carrier) }\nstruct MacMessageHoverBar: View {}\n"),
    ("perf-hover-tracker-per-bubble", "App/Chat/AssistantBubble.swift",
     "return bubble.rowHoverWiring(actions).bubbleWidth(.leading)\n",
     "return bubble.messageActions(side: .assistant).bubbleWidth(.leading)\n"),
    ("perf-observed-image-dictionary", SCREEN, "    private var images: [String: PlatformImage] = [:]\n", "    private var slots: [String: Slot] = [:]\n"),
    ("perf-monitor-unpaired", SCREEN,
     "final class V {\n    func install() { monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { $0 } }\n}\n",
     "final class V {\n    func install() { monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { $0 } }\n    deinit { NSEvent.removeMonitor(monitor) }\n}\n"),
    ("perf-state-model-init", SCREEN,
     "struct Inspector: View {\n    init(name: String) {\n        _profile = State(initialValue: BotProfileModel(botName: name))\n    }\n}\n",
     "struct Inspector: View {\n    @State private var profile = BotProfileModel()\n}\n"),
    ("perf-model-in-body", SCREEN,
     "struct Host: View {\n    @ViewBuilder\n    private func destination() -> some View {\n        ChatView(model: ChatModel(bot: bot), router: router)\n    }\n}\n",
     "struct Host: View {\n    @ViewBuilder\n    private func destination() -> some View {\n        ChatView(model: model, router: router)\n    }\n}\n"),
    ("perf-unguarded-write", ROSTER, "        live = snapshot.live\n", "        assignIfChanged(\\.live, snapshot.live)\n"),
    ("perf-unguarded-write", ROSTER, "        self.bots = next\n", "        let bots = next\n"),
    ("perf-unguarded-write", ROSTER, "        isLoaded = true\n", "        let isLoaded = true\n"),
    ("perf-unguarded-write", CHAT_MODEL, "        findMatches = []\n", "        assignIfChanged(\\.findMatches, [])\n"),
    ("perf-unguarded-write", CHAT_MODEL, "        isRunning = snapshot?.isRunning ?? false\n", "        assignIfChanged(\\.isRunning, snapshot?.isRunning ?? false)\n"),
    ("perf-unguarded-write", "App/ChatModel+StreamingPatch.swift", "        rowIDs = next.map(\\.id)\n", "        assignIfChanged(\\.rowIDs, next.map(\\.id))\n"),
    ("perf-dropped-value", ROSTER,
     "    private func publish() {\n        let next = combined.sorted()\n    }\n",
     "    private func publish() {\n        assignIfChanged(\\.bots, combined.sorted())\n    }\n"),
    ("perf-dropped-value", ROSTER,
     "    private func apply(_ snapshot: RosterSnapshot) async {\n        let rebuild = change.profiles\n        publish()\n    }\n",
     "    private func apply(_ snapshot: RosterSnapshot) async {\n        let rebuild = change.profiles\n        if rebuild { publish() }\n    }\n"),
    ("perf-drag-writes-binding", MAC_SHELL,
     "struct Handle: View {\n    @Binding var width: Double\n    var body: some View {\n        Color.clear.gesture(\n"
     "            DragGesture(minimumDistance: 1)\n                .onChanged { drag in\n                    width = drag.translation.width\n"
     "                }\n                .onEnded { _ in }\n        )\n    }\n}\n",
     "struct Handle: View {\n    let width: DragWidth\n    var body: some View {\n        Color.clear.gesture(\n"
     "            DragGesture(minimumDistance: 1)\n                .onChanged { drag in width.drag(by: drag.translation.width) }\n"
     "                .onEnded { _ in width.endDrag() }\n        )\n    }\n}\n"),
    ("perf-drag-writes-binding", SCREEN,
     "struct Row: View {\n    @AppStorage(\"k\") private var stored = 0.0\n    var body: some View {\n        Color.clear.gesture(\n"
     "            DragGesture().onChanged { stored += $0.translation.width }\n        )\n    }\n}\n",
     "struct Row: View {\n    @AppStorage(\"k\") private var stored = 0.0\n    @State private var live = 0.0\n    var body: some View {\n        Color.clear.gesture(\n"
     "            DragGesture().onChanged { live += $0.translation.width }.onEnded { _ in stored = live }\n        )\n    }\n}\n"),
    ("perf-shadow-radius", SCREEN, ".shadow(color: .black.opacity(0.35), radius: 40, y: 18)\n", ".shadow(color: .black.opacity(0.2), radius: 12, y: 4)\n"),
    ("perf-shadow-radius", SCREEN, ".shadow(color: .black, radius: 24)\n", ".shadow(color: .black, radius: 23)\n"),
    ("perf-open-ungated", "App/ChatModel.swift",
     "    func consume() async {\n        await TimelinePacer.consume(session.timelineSnapshots, apply: { next in\n            apply(next)\n        })\n    }\n",
     "    func consume() async {\n        await TimelinePacer.consume(session.timelineSnapshots, apply: { next in\n            guard let ready = openGate.admit(next) else { return }\n            apply(ready)\n        })\n    }\n"),
    ("perf-glass-over-fill", DESIGN,
     "configuration.label\n    .background(fill ?? PalTokens.control, in: Capsule())\n    .palGlass(Capsule())\n",
     "configuration.label\n    .palGlass(Capsule())\n"),
    ("perf-screen-reads-draft", CHAT_VIEW,
     "struct ChatView: View {\n    @State var draft = \"\"\n    var body: some View {\n        content.composerActivity(focused: composerFocused, draft: draft)\n    }\n}\n",
     "struct ChatView: View {\n    @State var draft = \"\"\n    var body: some View {\n        ChatBottomBar(draft: $draft, focused: $composerFocused)\n    }\n}\n"),
    ("perf-screen-reads-draft", CHAT_VIEW,
     "struct ChatView: View {\n    var body: some View {\n        Button(\"Send\") {}.disabled(draft.isEmpty)\n    }\n}\n",
     "struct ChatView: View {\n    var body: some View {\n        Button(\"Send\") {}.reportsComposerDraft(activity.draft)\n    }\n}\n"),
    ("perf-screen-reads-stream", CHAT_VIEW,
     "struct ChatView: View {\n    var body: some View {\n        ForEach(model.rowsNewestFirst) { row in Row(row) }\n    }\n}\n",
     "struct ChatView: View {\n    var body: some View {\n        ChatTranscriptList(model: model, scroll: scroll)\n    }\n}\n"),
    ("perf-screen-reads-stream", CHAT_VIEW,
     "struct ChatView: View {\n    var body: some View {\n        content.task(id: OlderDemand(wants: scroll.wantsOlder, state: model.olderHistory)) { await page() }\n    }\n}\n",
     "struct ChatView: View {\n    var body: some View {\n        content.modifier(ChatOlderPaging(model: model, scroll: scroll))\n    }\n}\n"),
    ("perf-shell-layout-probe", SHELL_LAYOUT,
     "struct MacShellLayout: Layout {\n    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {\n"
     "        let ideal = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0\n        return CGSize(width: 1, height: ideal)\n    }\n}\n",
     "struct MacShellLayout: Layout {\n    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {\n"
     "        CGSize(width: max(proposal.width ?? 1, 1), height: max(proposal.height ?? 1, 1))\n    }\n}\n"),
    ("perf-shell-layout-probe", SHELL_LAYOUT,
     "struct MacShellLayout: Layout {\n    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {\n"
     "        let sidebar = subviews[0].sizeThatFits(.unspecified).width\n    }\n}\n",
     "struct MacShellLayout: Layout {\n    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {\n"
     "        let sidebar = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width\n    }\n}\n"),
    ("perf-shell-layout-probe", SHELL_LAYOUT,
     "struct MacShellLayout: Layout {\n    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {\n"
     "        let size = subviews[0].sizeThatFits(proposal)\n        return size\n    }\n}\n",
     "struct MacShellLayout: Layout {\n    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {\n"
     "        proposal.replacingUnspecifiedDimensions()\n    }\n}\n"),
    ("perf-observed-frame-image", "App/Computer/ComputerModel.swift",
     "@MainActor\n@Observable\nfinal class ComputerModel {\n    private(set) var frame: CGImage?\n}\n",
     "@MainActor\n@Observable\nfinal class ComputerModel {\n    let frames = ComputerFrameSink()\n}\n"),
    ("perf-observed-frame-image", "App/Computer/ComputerModel.swift",
     "@MainActor\n@Observable\nfinal class ComputerModel {\n    var buffer: CVPixelBuffer?\n}\n",
     "@MainActor\n@Observable\nfinal class ComputerModel {\n    @ObservationIgnored var buffer: CVPixelBuffer?\n}\n"),
    ("perf-frame-cpu-draw", "App/Computer/ComputerSurface+macOS.swift",
     "override func draw(_ dirtyRect: NSRect) {\n    context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))\n}\n",
     "private func show(_ image: CGImage) {\n    layer?.contents = image\n}\n"),
    ("perf-unguarded-scroll-write", SCROLL_CONTROLLER,
     "func rowMoved() {\n    distanceFromNewest += delta\n    position.scrollTo(y: distanceFromNewest)\n}\n",
     "func rowMoved() {\n    distanceFromNewest += delta\n    write { $0.scrollTo(y: distanceFromNewest) }\n}\n"),
    ("perf-unguarded-scroll-write", SCROLL_CONTROLLER,
     "private func keepNewestInView() {\n    guard mode == .following else { return }\n    position.scrollTo(edge: .top)\n}\n",
     "private func jumpToBottom() {\n    withTransaction(transaction) { position.scrollTo(edge: .top) }\n}\n"),
    ("perf-foreach-regroup", "App/Profile/LibraryView.swift",
     "struct LibraryView: View {\n    @ViewBuilder\n    private var readySections: some View {\n        ForEach(MacLibraryGroup.groups(model.entries)) { group in macSection(group) }\n    }\n}\n",
     "struct LibraryView: View {\n    @ViewBuilder\n    private var readySections: some View {\n        ForEach(model.macItems) { item in macItem(item) }\n    }\n}\n"),
    ("perf-textkit-outside-layout", SELECTABLE_TEXT,
     "final class Coordinator {\n    private let measureLayout = NSLayoutManager()\n    private let measureStorage = NSTextStorage()\n}\n",
     "final class Coordinator {\n    func size(width: CGFloat) -> CGSize { SelectableSizeCache.shared.size(for: text, width: width) ?? .zero }\n}\n"),
    ("perf-textkit-outside-layout", SELECTABLE_TEXT,
     "func size() {\n    measureLayout.ensureLayout(for: measureContainer)\n    let used = measureLayout.usedRect(for: measureContainer)\n}\n",
     "func size() {\n    let used = session.size(width: width)\n}\n"),
    ("perf-row-openurl-closure", ASSISTANT_BUBBLE,
     "        .environment(\\.openURL, OpenURLAction { url in\n            return .handled\n        })\n",
     "        .environment(\\.openURL, links.action(files: files, open: openFile))\n"),
    ("perf-textview-scroll", SELECTABLE_TEXT,
     "final class PassiveTextView: NSTextView {\n    override func scrollWheel(with event: NSEvent) {\n        nextResponder?.scrollWheel(with: event)\n    }\n}\n",
     "final class PassiveTextView: NSTextView {\n    override func scroll(_ point: NSPoint) {\n        guard window?.firstResponder === self else { return }\n        super.scroll(point)\n    }\n}\n"),
    ("perf-markdown-foreach-not-equatable", MARKDOWN_VIEW,
     "ForEach(items) { item in\n    MarkdownItemView(item: item, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)\n}\n",
     "ForEach(items) { item in\n    MarkdownItemView(item: item, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)\n        .equatable()\n}\n"),
    ("perf-markdown-foreach-not-equatable", MARKDOWN_VIEW,
     "MarkdownQuote(content: ForEach(blocks) { block in\n    MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: false, isStreaming: false)\n})\n",
     "case .block(let block):\n    MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: false, isStreaming: false)\n"),
    ("perf-markdown-foreach-not-equatable", "App/Chat/ImageViewer/MacDocumentViewer.swift",
     "ForEach(items) { item in\n    MarkdownItemView(item: item)\n}\n",
     "ForEach(items) { item in\n    MarkdownItemView(item: item)\n        .equatable()\n}\n"),
    ("perf-markdown-foreach-not-equatable", MARKDOWN_VIEW,
     "ForEach(runs) { run in\n    MarkdownRunView(run: run, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)\n}\n",
     "ForEach(runs) { run in\n    MarkdownRunView(run: run, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)\n        .equatable()\n}\n"),
    ("perf-path-description-key", "Packages/PalDesign/Sources/PalDesign/EyeSurface.swift",
     "let key = mask.map { \"\\($0.fill != nil) \\($0.path.description)\" }.joined(separator: \"|\")\n",
     "let key = Key(mask)\n"),
    ("perf-path-description-key", "App/Chat/AvatarView.swift",
     "let key = shape.path.description\n",
     "let key = ShapeKey(shape)\n"),
    ("perf-path-description-key", SOLID,
     "let body = rig.body.map { \"\\($0.fill != nil) \\($0.path.description)\" }\nlet key = \"\\(detail)|\" + body.joined(separator: \"|\")\n",
     "let key = Key(detail: detail, signature: signature)\n"),
    ("perf-timestamp-uncached", ROWS, "ChatTimeSeparator(text: ChatTimestamp.label(for: date))\n", "ChatTimeSeparator(text: ChatTimestampCache.shared.label(for: date))\n"),
    ("perf-hover-bar-unconditional", MESSAGE_ACTIONS,
     "MessageChromeLayout(bubble: b, region: r, slot: s, hasReaction: false) {\n    MacMessageHoverBar(actions: actions)\n}\n",
     "MessageChromeLayout(bubble: b, region: r, slot: s, hasReaction: false) {\n    if barBuilt {\n        MacMessageHoverBar(actions: actions, layout: layout, visible: shown, focus: $focus)\n    }\n}\n"),
]


@pytest.mark.parametrize(("rule", "rel", "bad", "good"), CASES)
def test_violation_fails_and_clean_passes(tmp_path: Path, rule: str, rel: str, bad: str, good: str) -> None:
    assert rule in _rules(tmp_path / "red", rel, bad)
    assert rule not in _rules(tmp_path / "green", rel, good)


def test_non_interactive_glass_over_a_fill_is_allowed(tmp_path: Path) -> None:
    body = "label\n    .background(fill, in: Capsule())\n    .palGlass(Capsule(), interactive: false)\n"
    assert _rules(tmp_path, DESIGN, body) == []


def test_every_rule_has_a_fixture() -> None:
    covered = {rule for rule, *_ in CASES}
    declared = {lr.rule for lr in csp.LINE_RULES} | {rule for rule, _, _ in csp.BLOCK_RULES}
    assert declared == covered


def test_messages_name_the_replacement() -> None:
    wanted = {
        "perf-body-parse": "ParsedMarkdown",
        "perf-main-disk-read": "loadDetached",
        "perf-main-json": "loadDetached",
        "perf-queue-sync": "loadDetached",
        "perf-monitor-per-view": "shared monitor",
        "perf-state-model-init": "@LazyState",
        "perf-model-in-body": "ModelHost",
        "perf-unguarded-write": "assignIfChanged",
        "perf-timeline-unlisted": csp.ALLOWLIST_NAME,
        "perf-hover-unlisted": csp.ALLOWLIST_NAME,
        "perf-monitor-per-view": csp.ALLOWLIST_NAME,
        "perf-body-array-work": "rowsNewestFirst",
        "perf-row-reads-model": "ChatRowContext",
        "perf-hover-state-in-row-body": "MacMessageHoverBar",
        "perf-hover-pill-outside-tracker": "MessageChromePlacement.place",
        "perf-hover-tracker-per-bubble": "RowHoverState",
        "perf-observed-image-dictionary": "Slot",
        "perf-drag-writes-binding": "DragWidth",
    }
    messages = {lr.rule: lr.message for lr in csp.LINE_RULES}
    messages["perf-drag-writes-binding"] = " ".join(m for _, m in csp.drag_writes_binding(csp.Source(
        "@Binding var w: Double\nDragGesture().onChanged { w = 1 }\n")))
    for rule, needle in wanted.items():
        assert needle in messages[rule], rule


def test_eager_stack_message_names_lazyvstack(tmp_path: Path) -> None:
    body = "ScrollView {\n    VStack {\n        ForEach(rows) { Row($0) }\n    }\n}\n"
    found = csp.scan(_tree(tmp_path, {SCREEN: body}))
    assert [f.rule for f in found] == ["perf-eager-stack"] and "LazyVStack" in found[0].message


def test_parse_outside_a_view_body_is_allowed(tmp_path: Path) -> None:
    body = "struct Model {\n    func make() -> MarkdownDocument { MarkdownDocument(parsing: text) }\n}\n"
    assert _rules(tmp_path, SCREEN, body) == []


def test_state_model_init_ignores_non_view_types_and_plain_parameters(tmp_path: Path) -> None:
    app = "struct PalApp: App {\n    init() {\n        _rooms = State(initialValue: RoomsModel(services: s))\n    }\n}\n"
    param = "struct Screen: View {\n    init(model: ScreenModel) {\n        _model = State(initialValue: model)\n    }\n}\n"
    assert _rules(tmp_path / "a", SCREEN, app) == []
    assert _rules(tmp_path / "b", SCREEN, param) == []


def test_horizontal_scroll_and_lazy_stacks_are_not_eager_stacks(tmp_path: Path) -> None:
    horizontal = "ScrollView(.horizontal) {\n    VStack {\n        ForEach(chips) { Chip($0) }\n    }\n}\n"
    assert _rules(tmp_path, SCREEN, horizontal) == []


def test_allowlist_exempts_a_file_and_requires_a_reason(tmp_path: Path) -> None:
    body = "TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in Text(\"x\") }\nTimelineView(.periodic(from: .now, by: 1)) { _ in Text(\"y\") }\n"
    root = _tree(tmp_path, {SCREEN: body, "App/Other.swift": body})
    allow = root / csp.ALLOWLIST_NAME
    allow.write_text(json.dumps([{"rule": "perf-timeline-unlisted", "file": SCREEN, "reason": "bounded ticker"}]), encoding="utf-8")
    files = {f.path for f in csp.scan(root)}
    assert files == {"App/Other.swift"}
    allow.write_text(json.dumps([{"rule": "perf-timeline-unlisted", "file": SCREEN, "reason": " "}]), encoding="utf-8")
    with pytest.raises(SystemExit):
        csp.scan(root)


def test_allowlisted_monitor_file_passes_but_a_per_row_monitor_elsewhere_fails(tmp_path: Path) -> None:
    body = "monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { $0 }\nNSEvent.removeMonitor(monitor)\n"
    root = _tree(tmp_path, {"App/Mac/Window.swift": body, "App/Mac/Bubble.swift": body})
    (root / csp.ALLOWLIST_NAME).write_text(
        json.dumps([{"rule": "perf-monitor-per-view", "file": "App/Mac/Window.swift", "reason": "window-scoped"}]), encoding="utf-8")
    assert {f.path for f in csp.scan(root)} == {"App/Mac/Bubble.swift"}


def test_opt_out_marker_and_test_targets_are_exempt(tmp_path: Path) -> None:
    marked = ".shadow(color: .black, radius: 40) // perf-lint: ok\n"
    assert _rules(tmp_path / "a", SCREEN, marked) == []
    assert _rules(tmp_path / "b", "UITests/View.swift", ".shadow(color: .black, radius: 40)\n") == []
    assert _rules(tmp_path / "c", "Tools/Spike/View.swift", ".shadow(color: .black, radius: 40)\n") == []


def test_comments_do_not_trigger(tmp_path: Path) -> None:
    assert _rules(tmp_path, SCREEN, "// .shadow(color: .black, radius: 40)\n/* queue.sync { } */\n") == []


def test_baseline_absorbs_known_findings_but_not_new_ones(tmp_path: Path) -> None:
    root = _tree(tmp_path, {SCREEN: ".shadow(color: .black, radius: 40)\n"})
    found = csp.scan(root)
    csp.write_baseline(root / csp.BASELINE_NAME, found)
    baseline = csp.load_baseline(root / csp.BASELINE_NAME)
    assert csp.new_findings(found, baseline) == ([], 0)
    (root / SCREEN).write_text("\n.shadow(color: .black, radius: 40)\n.shadow(color: .red, radius: 60)\n", encoding="utf-8")
    fresh, stale = csp.new_findings(csp.scan(root), baseline)
    assert [f.text for f in fresh] == [".shadow(color: .red, radius: 60)"] and stale == 0


def test_planted_violation_is_reported_with_file_line_rule_and_fix(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"App/Planted.swift": "import SwiftUI\n\nlet m = try? Data(contentsOf: url)\n"})
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert "App/Planted.swift:3: [perf-main-disk-read]" in proc.stdout
    assert "CacheStore.loadDetached" in proc.stdout


REAL_SITES = [
    ("perf-shadow-radius", "App/Mac/MacModalSupport.swift"),
    ("perf-glass-over-fill", "Packages/PalDesign/Sources/PalDesign/Components/PalControls.swift"),
]


def test_real_tree_fails_without_baseline_and_passes_with_it() -> None:
    root = REPO / "apps" / "ios"
    without = {(f.rule, f.path) for f in csp.scan(root)}
    for site in REAL_SITES:
        assert site in without, site
    found = csp.scan(root)
    assert csp.new_findings(found, csp.load_baseline(root / csp.BASELINE_NAME))[0] == []
    entries = json.loads((root / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert all(set(e) == {"rule", "file", "text"} for e in entries)


PRE_FIX_SHELL = """struct MacSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var origin: Double?

    var body: some View {
        Color.clear
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = origin ?? width
                        origin = start
                        width = min(max(start + Double(drag.translation.width), 240), 400)
                    }
                    .onEnded { _ in origin = nil }
            )
    }
}

struct MacShellView: View {
    @AppStorage(MacMetrics.sidebarWidthKey) private var storedSidebarWidth = 280.0

    private var shellContent: some View {
        HStack(spacing: 0) {
            MacSidebar().overlay { MacSidebarResizeHandle(width: $storedSidebarWidth) }
        }
        .animation(.snappy(duration: 0.22), value: shell.isCompact)
        .animation(.snappy(duration: 0.22), value: shell.showsInspector)
    }
}
"""


def test_pre_fix_mac_shell_fails_and_the_real_file_passes_with_no_baseline_entries() -> None:
    ios = REPO / "apps" / "ios"
    allow = csp.load_allowlist(ios / csp.ALLOWLIST_NAME)
    old = [f for f in csp.violations(Path(MAC_SHELL), PRE_FIX_SHELL, allow)]
    assert {f.rule for f in old} == {"perf-drag-writes-binding", "perf-animation-container"}
    assert [f.line for f in old if f.rule == "perf-drag-writes-binding"] == [12]
    current = (ios / MAC_SHELL).read_text(encoding="utf-8")
    assert not csp.violations(Path(MAC_SHELL), current, allow)
    entries = json.loads((ios / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert not [e for e in entries if e["file"] == MAC_SHELL]


def test_unguarded_write_only_applies_to_the_guarded_model_file(tmp_path: Path) -> None:
    assert "perf-unguarded-write" not in _rules(tmp_path, SCREEN, "        live = snapshot.live\n")
    assert "perf-unguarded-write" not in _rules(tmp_path / "cmp", ROSTER, "        if live == snapshot.live { return }\n")


PRE_FIX_ROSTER_APPLY = """    private func apply(_ snapshot: RosterSnapshot) async {
        live = snapshot.live
        capabilities = snapshot.capabilities
        publish()
        isLoaded = true
    }

    private func publish() {
        bots = combined.sorted()
    }
"""


def test_pre_fix_roster_apply_fails_and_the_real_roster_model_passes(tmp_path: Path) -> None:
    old = [f for f in csp.scan(_tree(tmp_path / "old", {ROSTER: PRE_FIX_ROSTER_APPLY})) if f.rule == "perf-unguarded-write"]
    assert [f.text.split("=")[0].strip() for f in old] == ["live", "capabilities", "isLoaded", "bots"]
    current = (REPO / "apps" / "ios" / ROSTER).read_text(encoding="utf-8")
    assert not [f for f in csp.scan(_tree(tmp_path / "new", {ROSTER: current})) if f.rule == "perf-unguarded-write"]


def test_roster_publish_that_drops_its_list_fails_and_the_real_roster_model_passes(tmp_path: Path) -> None:
    dropped = "    private func publish() {\n        let next = combined.sorted()\n    }\n"
    assert [f.rule for f in csp.scan(_tree(tmp_path / "old", {ROSTER: dropped}))] == ["perf-dropped-value", "perf-dropped-value"]
    current = (REPO / "apps" / "ios" / ROSTER).read_text(encoding="utf-8")
    assert not [f for f in csp.scan(_tree(tmp_path / "new", {ROSTER: current})) if f.rule == "perf-dropped-value"]
    parent = subprocess.run(
        ["git", "show", f"1a45067c:apps/ios/{ROSTER}"], cwd=REPO, capture_output=True, text=True, check=False
    )
    if parent.returncode == 0:
        found = [f.line for f in csp.scan(_tree(tmp_path / "main", {ROSTER: parent.stdout})) if f.rule == "perf-dropped-value"]
        assert len(found) == 2


def test_dropped_value_only_applies_to_the_guarded_model_file(tmp_path: Path) -> None:
    assert "perf-dropped-value" not in _rules(tmp_path, SCREEN, "    func publish() {\n        let next = 1\n    }\n")


PRE_FIX_CHAT_OPEN = """    private func consumeTimeline(_ session: ChatSession) async {
        await TimelinePacer.consume(session.timelineSnapshots, apply: { next in
            apply(next)
            if next.sessionID != nil { scheduleCacheSave() }
        })
    }
"""


def test_pre_fix_chat_open_fails_and_the_real_chat_model_passes(tmp_path: Path) -> None:
    old = [f for f in csp.scan(_tree(tmp_path / "old", {"App/ChatModel.swift": PRE_FIX_CHAT_OPEN})) if f.rule == "perf-open-ungated"]
    assert [f.line for f in old] == [2]
    current = (REPO / "apps" / "ios" / "App" / "ChatModel.swift").read_text(encoding="utf-8")
    assert not [f for f in csp.scan(_tree(tmp_path / "new", {"App/ChatModel.swift": current})) if f.rule == "perf-open-ungated"]


AVATAR = "Packages/PalDesign/Sources/PalDesign/BotAvatarView.swift"
SIDEBAR = "App/Mac/MacSidebar.swift"

PRE_FIX_AVATAR = """    public var body: some View {
        AvatarStage(
            clock: animated ? resolvedClock(solid: content.isSolid) : nil,
            frameInterval: reduceMotion ? 1.0 / 20 : 1.0 / 60,
        )
    }

    var stage: some View {
        TimelineView(AvatarSchedule(clock: clock, frameInterval: frameInterval)) { context in
            frame(pose: clock.pose(at: context.date))
        }
    }

    func body(content: Content) -> some View {
        content.background {
            Color.clear.onContinuousHover { phase in look(phase) }
        }
    }
"""

PRE_FIX_SIDEBAR = """struct MacSidebar: View {
    var expanded: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(MacShell.ordered(roster)) { bot in MacBotRow(bot: bot) }
            }
        }
    }
}
"""


def test_pre_fix_avatar_and_sidebar_fail_and_the_real_files_pass() -> None:
    ios = REPO / "apps" / "ios"
    allow = csp.load_allowlist(ios / csp.ALLOWLIST_NAME)
    old = {f.rule for f in csp.violations(Path(AVATAR), PRE_FIX_AVATAR, None)}
    assert {"perf-timeline-unlisted", "perf-timeline-interval", "perf-hover-unlisted"} <= old
    assert "perf-timeline-interval" in {f.rule for f in csp.violations(Path(AVATAR), PRE_FIX_AVATAR, allow)}
    assert "perf-eager-stack" in {f.rule for f in csp.violations(Path(SIDEBAR), PRE_FIX_SIDEBAR, allow)}
    for rel in (AVATAR, SIDEBAR):
        current = (ios / rel).read_text(encoding="utf-8")
        assert not csp.violations(Path(rel), current, allow), rel
    entries = json.loads((ios / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert not [e for e in entries if e["file"] in (AVATAR, SIDEBAR)]


HOME = "App/HomeView.swift"
ROOM_ROWS = "App/Rooms/RoomRows.swift"
PRE_FIX_ROW_AVATARS = {
    SIDEBAR: "struct MacBotAvatar: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: diameter * 1.2, mood: roster.avatarMood(for: bot.name))\n    }\n}\n",
    HOME: "struct Row: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: PalMetrics.homeRowAvatarFrame, mood: mood)\n    }\n}\n",
    ROOM_ROWS: "struct Row: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: size * 1.15)\n    }\n}\n",
}


def test_pre_fix_row_avatars_fail_and_the_real_files_pass(tmp_path: Path) -> None:
    ios = REPO / "apps" / "ios"
    for rel, body in PRE_FIX_ROW_AVATARS.items():
        assert [f.rule for f in csp.violations(Path(rel), body)] == ["perf-avatar-row-slot"], rel
        opted = body.replace("mood: mood)", "mood: mood, sharesSlot: true)").replace("bot.name))", "bot.name), sharesSlot: true)")
        opted = opted.replace("* 1.15)", "* 1.15, sharesSlot: true)")
        assert not csp.violations(Path(rel), opted), rel
        assert not csp.violations(Path(rel), body.replace(")\n    }", ", animated: false)\n    }", 1)), rel
        assert not [f for f in csp.violations(Path(rel), (ios / rel).read_text(encoding="utf-8")) if f.rule == "perf-avatar-row-slot"], rel
    assert not csp.violations(Path(SCREEN), PRE_FIX_ROW_AVATARS[SIDEBAR])


def test_allowlisted_timeline_file_still_fails_the_minimum_interval(tmp_path: Path) -> None:
    body = "TimelineView(AvatarSchedule(frameInterval: 1.0 / 60)) { _ in Text(\"x\") }\n"
    root = _tree(tmp_path, {AVATAR: body})
    (root / csp.ALLOWLIST_NAME).write_text(
        json.dumps([{"rule": "perf-timeline-unlisted", "file": AVATAR, "reason": "bounded"}]), encoding="utf-8")
    assert [f.rule for f in csp.scan(root)] == ["perf-timeline-interval"]


CHAT_VIEW = "App/ChatView.swift"
FAVICONS = "App/Chat/FaviconStore.swift"
MESSAGE_ACTIONS = "App/Mac/MacMessageActions.swift"

PRE_FIX_CHAT_VIEW = """struct ChatView: View {
    private var chat: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows.reversed()) { row in
                    ChatRowView(row: row, model: model) { link in open(link) }
                        .newestFirst()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.frame(in: .named(ChatScrollController.contentSpace)).minY
                        } action: { scroll.rowMoved(row.id, contentMinY: $0) }
                }
            }
        }
        .onChange(of: model.rows.map(\\.id), initial: true) { _, ids in scroll.rowsChanged(ids) }
    }
}
"""

PRE_FIX_ROWS = """struct ChatRowView: View {
    var body: some View {
        UnreadDivider(label: "New", ink: BubblePalette.ink(accent: model.chatAccent))
        UserBubble(text: text, accent: model.chatAccent, highlight: findQuery)
        MessageActions(reaction: model.reactions[id])
    }
    private var findQuery: String { model.isFinding && model.findMatchIDs.contains(row.id) ? model.findQuery : "" }
    private var isCurrentMatch: Bool { model.currentFindRowID == row.id }
    ConnectionRequestCard(card: card, answering: model.answeringConnections)
}
"""

PRE_FIX_FAVICONS = """@MainActor
@Observable
final class FaviconCache {
    private var images: [String: PlatformImage] = [:]

    func image(for url: URL, pointSize: CGFloat) -> PlatformImage? {
        if let image = images[host] { return image.roundedIcon(points: pointSize) }
        return nil
    }
}
"""

PRE_FIX_MESSAGE_ACTIONS = """final class TrackingView: NSView {
    override func viewDidMoveToWindow() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            return event
        }
    }
}
"""


def test_pre_fix_chat_view_rows_favicons_and_monitors_fail_and_the_real_files_pass() -> None:
    ios = REPO / "apps" / "ios"
    allow = csp.load_allowlist(ios / csp.ALLOWLIST_NAME)
    pre_fix = {
        CHAT_VIEW: (PRE_FIX_CHAT_VIEW, {"perf-geometry-per-row", "perf-body-array-work"}),
        ROWS: (PRE_FIX_ROWS, {"perf-row-reads-model"}),
        FAVICONS: (PRE_FIX_FAVICONS, {"perf-redraw-per-call", "perf-observed-image-dictionary"}),
        MESSAGE_ACTIONS: (PRE_FIX_MESSAGE_ACTIONS, {"perf-monitor-per-view", "perf-monitor-unpaired"}),
    }
    for rel, (body, rules) in pre_fix.items():
        assert rules <= {f.rule for f in csp.violations(Path(rel), body, None)}, rel
        current = (ios / rel).read_text(encoding="utf-8")
        assert not [f for f in csp.violations(Path(rel), current, allow) if f.rule in rules], rel
    entries = json.loads((ios / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    removed = {"perf-geometry-per-row", "perf-redraw-per-call", "perf-monitor-per-view"}
    assert not [e for e in entries if e["file"] in pre_fix and e["rule"] in removed]


def test_row_reads_model_only_applies_to_the_chat_rows_file(tmp_path: Path) -> None:
    body = "let accent = model.chatAccent\n"
    assert _rules(tmp_path / "a", SCREEN, body) == []
    assert _rules(tmp_path / "b", ROWS, body) == ["perf-row-reads-model"]


def test_monitor_with_a_removal_in_the_file_is_paired(tmp_path: Path) -> None:
    body = "monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { $0 }\nNSEvent.removeMonitor(monitor)\n"
    assert "perf-monitor-unpaired" not in _rules(tmp_path, SCREEN, body)


PRE_FIX_ASSISTANT_BUBBLE = """
struct AssistantBubble: View {
    @ViewBuilder
    private var bubbleContent: some View {
        MarkdownView(parsed: parsed, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatBubble(style: BubblePalette.agentBubble) {
                bubbleContent.bubbleTextSelection()
            }
        }
    }
}
"""


def test_pre_fix_assistant_bubble_fails_and_the_real_rows_file_passes() -> None:
    ios = REPO / "apps" / "ios"
    rules = {f.rule for f in csp.violations(Path(ROWS), PRE_FIX_ASSISTANT_BUBBLE)}
    assert {"perf-selection-island", "perf-table-in-text-bubble"} <= rules
    for rel in (ROWS, "App/Chat/AssistantBubble.swift"):
        current = (ios / rel).read_text(encoding="utf-8")
        assert not [f for f in csp.violations(Path(rel), current) if f.rule in {"perf-selection-island", "perf-table-in-text-bubble"}], rel
    entries = json.loads((ios / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert not [e for e in entries if e["file"] == "App/Chat/MarkdownTableView.swift"]


def test_selection_over_one_text_view_is_allowed_and_only_rows_are_checked(tmp_path: Path) -> None:
    single = "ChatBubble(fill: paint) {\n    InlineText(text: body).bubbleTextSelection()\n}\n"
    assert _rules(tmp_path / "a", ROWS, single) == []
    island = "ChatBubble(fill: paint) {\n    MarkdownView(segment: s).textSelection(.enabled)\n}\n"
    assert _rules(tmp_path / "b", ROWS, island) == ["perf-selection-island"]
    assert _rules(tmp_path / "c", SCREEN, island) == []
    assert _rules(tmp_path / "d", SCREEN, "MarkdownView(parsed: parsed, highlight: h, isCurrentMatch: false)\n") == []


PRE_FIX_HOVER_PILL = """struct MacMessageActionsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if let actions {
            switch side {
            case .user:
                content.overlay(alignment: .leading) {
                    MacMessageHoverBar(actions: actions)
                        .alignmentGuide(.leading) { $0[.trailing] + messageBarGap }
                }
            case .assistant:
                content.overlay(alignment: .trailing) {
                    MacMessageHoverBar(actions: actions)
                        .alignmentGuide(.trailing) { $0[.leading] - messageBarGap }
                }
            }
        }
    }
}
"""


def test_pre_fix_hover_pill_fails_naming_the_placement_function_and_the_real_file_passes() -> None:
    rel = Path("App/Mac/MacMessageActions.swift")
    old = [f for f in csp.violations(rel, PRE_FIX_HOVER_PILL, None) if f.rule == "perf-hover-pill-outside-tracker"]
    assert [f.text for f in old] == [
        "content.overlay(alignment: .leading) {",
        ".alignmentGuide(.leading) { $0[.trailing] + messageBarGap }",
        "content.overlay(alignment: .trailing) {",
        ".alignmentGuide(.trailing) { $0[.leading] - messageBarGap }",
    ]
    assert all("MessageChromePlacement.place" in f.message for f in old)
    ios = REPO / "apps" / "ios"
    current = (ios / rel).read_text(encoding="utf-8")
    assert not csp.violations(rel, current, csp.load_allowlist(ios / csp.ALLOWLIST_NAME))
    entries = json.loads((ios / csp.BASELINE_NAME).read_text(encoding="utf-8-sig"))
    assert not [e for e in entries if e["file"] == rel.as_posix()]


def test_lazy_state_and_model_host_are_the_sanctioned_model_owners(tmp_path: Path) -> None:
    lazy = (
        "struct Inspector: View {\n    @LazyState private var profile: BotProfileModel\n    init(name: String) {\n"
        "        _profile = LazyState { BotProfileModel(botName: name) }\n    }\n}\n"
    )
    host = (
        "struct Host: View {\n    @ViewBuilder\n    private func destination() -> some View {\n"
        "        ModelHost { ChatModel(bot: bot) } content: { model in\n            ChatView(model: model, router: router)\n        }\n    }\n}\n"
    )
    assert _rules(tmp_path / "lazy", SCREEN, lazy) == []
    assert _rules(tmp_path / "host", SCREEN, host) == []


def test_new_rule_messages_name_the_replacement() -> None:
    wanted = {
        "perf-screen-reads-draft": "reportsComposerDraft",
        "perf-screen-reads-stream": "ChatTranscriptReaders",
        "perf-observed-frame-image": "ComputerFrameSink",
        "perf-frame-cpu-draw": "layer.contents",
        "perf-unguarded-scroll-write": "write {",
        "perf-foreach-regroup": "MacLibraryItems",
        "perf-textkit-outside-layout": "SelectableSizeCache",
        "perf-row-openurl-closure": "FileLinkRouter",
        "perf-path-description-key": "Hashable struct",
        "perf-timestamp-uncached": "ChatTimestampCache",
    }
    messages = {lr.rule: lr.message for lr in csp.LINE_RULES}
    for rule, needle in wanted.items():
        assert needle in messages[rule], rule
    probe = " ".join(m for _, m in csp.shell_layout_probe(csp.Source("x.sizeThatFits(.zero)\n")))
    assert "ProposedViewSize(width: nil, height: bounds.height)" in probe
    unequatable = " ".join(m for _, m in csp.markdown_foreach_not_equatable(csp.Source("ForEach(a) { MarkdownItemView(item: $0) }\n")))
    assert ".equatable()" in unequatable
    bar = " ".join(m for _, m in csp.hover_bar_unconditional(csp.Source("MacMessageHoverBar(actions: a)\n")))
    assert "barBuilt" in bar
    textview = " ".join(m for _, m in csp.textview_scrolls_transcript(csp.Source("final class T: NSTextView {\n}\n")))
    assert "override func scroll(_ point: NSPoint)" in textview


def test_screen_rules_reach_only_the_chat_screen(tmp_path: Path) -> None:
    body = "struct Other: View {\n    var body: some View { Text(\"\\(model.rows.count)\") }\n    func f() { send(draft) }\n}\n"
    assert _rules(tmp_path, "App/Chat/ChatTranscriptReaders.swift", body) == []


def test_healthy_per_key_image_slot_is_not_an_observed_frame(tmp_path: Path) -> None:
    slot = "@MainActor\n@Observable\nfinal class Slot {\n    fileprivate(set) var image: PlatformImage?\n}\n"
    assert _rules(tmp_path, "App/Chat/FaviconStore.swift", slot) == []
    sink = "@MainActor\nfinal class ComputerFrameSink {\n    private(set) var latest: CGImage?\n}\n"
    assert _rules(tmp_path / "sink", "App/Computer/ComputerFrameSink.swift", sink) == []


def test_textkit_is_allowed_in_the_layout_home_only(tmp_path: Path) -> None:
    body = "final class Session {\n    private let manager = NSLayoutManager()\n    func size() { manager.ensureLayout(for: container) }\n}\n"
    assert _rules(tmp_path / "home", "App/Chat/SelectableTextLayout.swift", body) == []
    assert "perf-textkit-outside-layout" in _rules(tmp_path / "elsewhere", "App/Chat/Other.swift", body)


def test_a_document_viewer_may_own_its_open_url_action(tmp_path: Path) -> None:
    body = "content.environment(\\.openURL, OpenURLAction(handler: route))\n"
    assert "perf-row-openurl-closure" not in _rules(tmp_path, "App/Chat/ImageViewer/MacDocumentViewer.swift", body)


PRE_FIX_SHARED_COUNTER_TEST = """\
@Test("drawing the same pose twice builds the silhouette once")
func samePoseBuildsOnce() {
    let before = SolidFrame.cache.statistics
    let first = make(avatar, pose)
    let after = SolidFrame.cache.statistics
    #expect(after.misses - before.misses == 1)
}
"""


def test_a_test_reading_a_process_wide_cache_counter_fails_and_the_real_tests_pass(tmp_path: Path) -> None:
    rel = "Packages/PalDesign/Tests/PalDesignTests/SolidFrameCacheTests.swift"
    root = _tree(tmp_path, {rel: PRE_FIX_SHARED_COUNTER_TEST})
    assert [(f.rule, f.line) for f in csp.scan(root)] == [("perf-test-shared-counter", 3), ("perf-test-shared-counter", 5)]
    real = REPO / "apps" / "ios" / rel
    assert csp.violations(Path(rel), real.read_text(encoding="utf-8"), None, csp.TEST_LINE_RULES, ()) == []


def test_test_files_get_only_the_test_rules(tmp_path: Path) -> None:
    root = _tree(tmp_path, {
        "Tests/ParseTests.swift": "var body: some View { MarkdownDocument(parsing: text) }\n",
        "Tests/Fixtures/Cache.swift": "let s = SolidFrame.cache.statistics\n",
    })
    assert csp.scan(root) == []


def test_a_computed_image_property_is_not_an_observed_frame(tmp_path: Path) -> None:
    body = "@MainActor\n@Observable\nfinal class Intro {\n    var photo: CGImage? { draft?.preview }\n}\n"
    assert "perf-observed-frame-image" not in _rules(tmp_path, "App/Mac/Intro.swift", body)


def test_an_allowlisted_still_image_passes_and_other_files_still_fail(tmp_path: Path) -> None:
    body = "@MainActor\n@Observable\nfinal class Profile {\n    private(set) var photo: CGImage?\n}\n"
    allow = csp.Allowlist(frozenset({("perf-observed-frame-image", "App/Settings/Profile.swift")}))
    assert csp.violations(Path("App/Settings/Profile.swift"), body, allow) == []
    assert [f.rule for f in csp.violations(Path("App/Settings/Other.swift"), body, allow)] == ["perf-observed-frame-image"]
