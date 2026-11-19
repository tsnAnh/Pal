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
    ("perf-body-format", SCREEN,
     "struct Row: View {\n    var body: some View {\n        Text(\"Next run \\(next.formatted(date: .abbreviated, time: .shortened))\")\n    }\n}\n",
     "struct Row: View {\n    let label: String\n    var body: some View { Text(label) }\n}\nfunc label(_ d: Date) -> String { d.formatted() }\n"),
    ("perf-body-format", SCREEN,
     "struct Row: View {\n    var body: some View {\n        let day = Calendar.current.startOfDay(for: date)\n        Text(\"\\(day)\")\n    }\n}\n",
     "struct Row: View {\n    let day: Date\n    var body: some View { Text(\"\\(day)\") }\n}\n"),
    ("perf-avatar-row-slot", "App/Mac/MacSidebar.swift",
     "struct R: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: 24, mood: mood)\n    }\n}\n",
     "struct R: View {\n    var body: some View {\n        BotAvatarView(spec: bot.spec, size: 24, mood: mood, sharesSlot: true)\n    }\n}\n"),
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
    ("perf-dropped-value", ROSTER,
     "    private func publish() {\n        let next = combined.sorted()\n    }\n",
     "    private func publish() {\n        assignIfChanged(\\.bots, combined.sorted())\n    }\n"),
    ("perf-dropped-value", ROSTER,
     "    private func apply(_ snapshot: RosterSnapshot) async {\n        let rebuild = change.profiles\n        publish()\n    }\n",
     "    private func apply(_ snapshot: RosterSnapshot) async {\n        let rebuild = change.profiles\n        if rebuild { publish() }\n    }\n"),
    ("perf-shadow-radius", SCREEN, ".shadow(color: .black.opacity(0.35), radius: 40, y: 18)\n", ".shadow(color: .black.opacity(0.2), radius: 12, y: 4)\n"),
    ("perf-shadow-radius", SCREEN, ".shadow(color: .black, radius: 24)\n", ".shadow(color: .black, radius: 23)\n"),
    ("perf-glass-over-fill", DESIGN,
     "configuration.label\n    .background(fill ?? PalTokens.control, in: Capsule())\n    .palGlass(Capsule())\n",
     "configuration.label\n    .palGlass(Capsule())\n"),
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
        "perf-state-model-init": "@State private var model",
        "perf-unguarded-write": "assignIfChanged",
        "perf-timeline-unlisted": csp.ALLOWLIST_NAME,
        "perf-hover-unlisted": csp.ALLOWLIST_NAME,
        "perf-monitor-per-view": csp.ALLOWLIST_NAME,
        "perf-body-array-work": "rowsNewestFirst",
        "perf-row-reads-model": "ChatRowContext",
        "perf-observed-image-dictionary": "Slot",
    }
    messages = {lr.rule: lr.message for lr in csp.LINE_RULES}
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
    ("perf-body-parse", "App/Chat/RoutineOutputRow.swift"),
    ("perf-main-disk-read", "App/Chat/Rich/MermaidRenderer.swift"),
    ("perf-main-disk-read", "App/Chat/FilePreviewSheet.swift"),
    ("perf-main-json", "App/RosterModel.swift"),
    ("perf-queue-sync", "Packages/PalKit/Sources/PalProtocol/Cache/CacheStore.swift"),
    ("perf-animation-container", "App/Mac/MacShell.swift"),
    ("perf-eager-stack", "App/Mac/MacSidebarRail.swift"),
    ("perf-state-model-init", "App/Mac/MacInspector.swift"),
    ("perf-model-in-body", "App/Mac/MacModals.swift"),
    ("perf-model-in-body", "App/PalApp.swift"),
    ("perf-shadow-radius", "App/Mac/MacModalSupport.swift"),
    ("perf-shadow-radius", "App/Mac/MacPalette.swift"),
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
