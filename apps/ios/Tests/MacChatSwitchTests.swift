#if os(macOS)
import AppKit
import Foundation
import PalDesign
import PalProtocol
import PalRoster
import SwiftUI
import Testing

@testable import Pal
@testable import PalChat

private struct SlowTimelineStore: TimelineStore {
    let latency: Duration
    let timeline: CachedTimeline?

    func load() async -> CachedTimeline? {
        try? await Task.sleep(for: latency)
        return timeline
    }

    func save(_ timeline: CachedTimeline) {}
}

struct SwitchOpen {
    var bot: String
    var firstModelRows = 0
    var firstContent = 0.0
    var settledContent = 0.0
    var modelRowsHitZero = 0
    var longestBlankFrames = 0
    var frames = 0
    var series: [String] = []

    var contentRatio: Double { settledContent > 0 ? firstContent / settledContent : 0 }

    var line: String {
        String(
            format: "%@ first rows %d content %.0f settled %.0f (x%.3f) model rows hit 0: %d longest blank run %d of %d frames",
            bot, firstModelRows, firstContent, settledContent, contentRatio, modelRowsHitZero, longestBlankFrames, frames
        )
    }
}

@MainActor
private final class SwitchSampler {
    private(set) var open: SwitchOpen
    var contentHeight = 0.0
    private var blankRun = 0
    private var sawRows = false

    init(bot: String) { open = SwitchOpen(bot: bot) }

    func frame(model: ChatModel) {
        let rows = model.rows.count
        if open.frames == 0 {
            open.firstModelRows = rows
            open.firstContent = contentHeight
        }
        open.frames += 1
        let mark = String(format: "%.0f/%d", contentHeight, rows)
        if open.series.last != mark, open.series.count < 12 { open.series.append("f\(open.frames):" + mark) }
        if rows == 0, sawRows { open.modelRowsHitZero += 1 }
        sawRows = sawRows || rows > 0
        let blank = rows == 0 || contentHeight < SwitchStage.blankContent
        blankRun = blank ? blankRun + 1 : 0
        open.longestBlankFrames = max(open.longestBlankFrames, blankRun)
        open.settledContent = contentHeight
    }
}

@MainActor
private final class SwitchStage {
    static let blankContent = 200.0
    static let chief = "chief"
    static let small = "small"

    let roster: RosterModel
    let links: BotLinks
    let cache = ChatModelCache()
    private var version: UInt64 = 10
    private var host: MacChatBenchHost?
    private var current: ChatModel?

    init(restoreLatency: Duration, persisted: [String: CachedTimeline] = [:]) throws {
        roster = try rebuildRoster()
        links = BotLinks(connection: roster.connection, timelineStore: { SlowTimelineStore(latency: restoreLatency, timeline: persisted[$0]) })
    }

    static func row(_ name: String) -> BotRow {
        BotRow(
            name: name, isDefault: false, isPrimary: false, isPinned: false, displayName: name, conversationID: nil,
            preview: ClassifiedPreview(kind: .plain, text: ""), lastActive: nil,
            spec: BotAvatarSpec(name: name, uiMeta: nil, photo: nil), accent: nil, usesPrimaryLook: false, sessionIDs: []
        )
    }

    private func world(for bot: String) -> RebuildWorld {
        MacChatBenchFixture.world(streamingTail: false, messageCount: bot == Self.chief ? 200 : 20, images: bot == Self.chief)
    }

    private func mount(_ model: ChatModel, scroll: ChatScrollController) {
        let environment = MacChatBenchEnvironment(model: model)
        let root = environment.surface(draft: MacChatBenchDraft(), scroll: scroll).id(UUID())
        if let host { host.view.rootView = AnyView(root) } else {
            host = MacChatBenchHost(root: root, size: MacChatBench.pane)
        }
    }

    func firstVisit(_ bot: String) async throws {
        let model = cache.model(for: Self.row(bot), links: links, roster: roster)
        mount(model, scroll: ChatScrollController(layout: model.layout))
        current?.stop()
        current = model
        model.start()
        try await Task.sleep(for: .milliseconds(100))
        version += 1
        model.apply(world(for: bot).snapshot(version: version))
        try await Task.sleep(for: .milliseconds(2_000))
    }

    func switchTo(_ bot: String, dwell: Duration) async throws -> SwitchOpen {
        let model = cache.model(for: Self.row(bot), links: links, roster: roster)
        let scroll = ChatScrollController(layout: model.layout)
        let sampler = SwitchSampler(bot: bot)
        scroll.sampleSink = { sampler.contentHeight = $0.geometry.contentHeight }
        mount(model, scroll: scroll)
        current?.stop()
        current = model
        model.start()
        let clock = ContinuousClock()
        let end = clock.now + dwell
        while clock.now < end {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            sampler.frame(model: model)
        }
        return sampler.open
    }

    func close() {
        current?.stop()
        host?.close()
    }
}

private func persistedTimeline(rows count: Int) -> CachedTimeline {
    let entries = (0..<count).map { index in
        TimelineEntryWire(
            id: "entry-\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "message \(index) " + String(repeating: "word ", count: 12 + index % 40),
            timestamp: 1_700_000_000 + Double(index) * 60, rowID: index + 1
        )
    }
    return CachedTimeline(sessionID: "session-chief", entries: entries, older: .start, revision: "r1")
}

@MainActor
@Suite("Mac chat switching", .serialized)
struct MacChatSwitchTests {
    static let switches = 20
    static let heightTolerance = 0.01
    static let restoreLatency = Duration.seconds(2)

    @Test("switching between a 200 row chat and a small one 20 times, with a 2 s restore, never shows an empty pane and opens at the settled height")
    func switchingBackAndForthNeverEmpties() async throws {
        let stage = try SwitchStage(restoreLatency: Self.restoreLatency)
        defer { stage.close() }
        try await stage.firstVisit(SwitchStage.chief)
        try await stage.firstVisit(SwitchStage.small)
        for number in 1...Self.switches {
            let bot = number.isMultiple(of: 2) ? SwitchStage.small : SwitchStage.chief
            let dwell: Duration = bot == SwitchStage.chief ? .milliseconds(2_400) : .milliseconds(500)
            let open = try await stage.switchTo(bot, dwell: dwell)
            print("SWITCH open \(number): \(open.line)\nSERIES \(open.series.joined(separator: " "))")
            let context = Comment(rawValue: "switch \(number): \(open.line)")
            #expect(open.firstModelRows > 0, context)
            #expect(open.modelRowsHitZero == 0, context)
            #expect(open.longestBlankFrames <= 1, context)
            #expect(abs(open.contentRatio - 1) <= Self.heightTolerance, context)
        }
    }

    @Test("the first open of a chat in a process shows its last-known rows at once even when the restore takes 2 s")
    func firstOpenShowsLastKnownRows() async throws {
        let stage = try SwitchStage(restoreLatency: Self.restoreLatency, persisted: [SwitchStage.chief: persistedTimeline(rows: 200)])
        defer { stage.close() }
        await stage.links.preload([SwitchStage.chief])
        let open = try await stage.switchTo(SwitchStage.chief, dwell: .milliseconds(2_400))
        print("FIRSTOPEN \(open.line)\nSERIES \(open.series.joined(separator: " "))")
        let context = Comment(rawValue: open.line)
        #expect(open.firstModelRows > 0, context)
        #expect(open.longestBlankFrames <= 1, context)
    }
}
#endif
