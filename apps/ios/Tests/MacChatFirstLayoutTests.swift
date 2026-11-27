#if os(macOS)
import AppKit
import Foundation
import PalChat
import PalDesign
import PalRoster
import Testing

@testable import Pal

struct FirstLayoutOpen {
    var report: ChatOpenSettleMeter.Report
    var maxContent: Double
    var rowsAfterData: Int
    var largestFirstRow: Double
    var sustainedPastEnd: Double
    var worstSample: String

    var line: String {
        String(
            format: "first %.0f settled %.0f max %.0f (x%.2f) in %d ms, past end %.1f sustained %.1f, rows hit 0: %d, largest first row %.0f | %@",
            report.firstContent, report.settledContent, maxContent, maxContent / max(report.settledContent, 1), report.settleMilliseconds,
            report.maxPastEnd, sustainedPastEnd, report.rowsHitZero, largestFirstRow, worstSample
        )
    }
}

@MainActor
private final class FirstLayoutRecorder {
    static let frameMilliseconds = 8
    static let sustainedMilliseconds = 34
    static let pastEndLimit = 8.0

    private(set) var meter = ChatOpenSettleMeter()
    private(set) var maxContent = 0.0
    private(set) var sustained = 0.0
    private(set) var worstSample = ""
    private(set) var firstRowHeights: [String: Double] = [:]
    private var pending: (bucket: Int, sample: ChatScrollSample)?
    private var runStart: Int?
    private var runWorst = 0.0
    private var worstPast = 0.0

    func record(_ sample: ChatScrollSample, at time: Int) {
        let bucket = time / Self.frameMilliseconds
        if let held = pending, held.bucket != bucket { present(held.sample, at: held.bucket * Self.frameMilliseconds) }
        pending = (bucket, sample)
    }

    func recordRow(_ id: String, _ frame: CGRect) {
        if firstRowHeights[id] == nil { firstRowHeights[id] = Double(frame.height) }
    }

    func rows(_ count: Int) { meter.rows(count: count) }

    func finish() {
        if let held = pending { present(held.sample, at: held.bucket * Self.frameMilliseconds) }
        if runStart != nil { sustained = max(sustained, runWorst) }
    }

    private func present(_ sample: ChatScrollSample, at time: Int) {
        let geometry = sample.geometry
        meter.geometry(geometry, atMilliseconds: time)
        maxContent = max(maxContent, geometry.contentHeight)
        let over = geometry.contentHeight > 0 ? geometry.overshoot : 0
        if over > Self.pastEndLimit {
            runStart = runStart ?? time
            runWorst = max(runWorst, over)
        } else if let began = runStart {
            if time - began >= Self.sustainedMilliseconds { sustained = max(sustained, runWorst) }
            runStart = nil
            runWorst = 0
        }
        guard over > worstPast else { return }
        worstPast = over
        worstSample = String(
            format: "t=%d offset %.1f content %.1f container %.1f insets %.1f/%.1f writer %@",
            time, geometry.offsetY, geometry.contentHeight, geometry.containerHeight, geometry.insetTop, geometry.insetBottom, sample.writer.rawValue
        )
    }
}

@MainActor
private final class FirstLayoutStage {
    static let rows = 160
    static let frames = 200
    private static let tallRows = 8

    let roster: RosterModel
    let links: BotLinks
    private let world = FirstLayoutStage.tallTailWorld()
    private var version: UInt64 = 10

    private static func tallTailWorld() -> RebuildWorld {
        var world = MacChatBenchFixture.world(streamingTail: false, messageCount: rows - tallRows, images: true)
        let paragraph = "The scheduler picks the next job by priority, then by age, then by owner, and it skips any job whose dependencies have not finished. "
        for index in 0..<tallRows {
            let at = rebuildAt(Double(rows + index) * 95)
            if index.isMultiple(of: 2) {
                world.append(rebuildUser("tu\(index)", "Walk me through the whole plan again, step by step.", at: at))
            } else {
                let body = (0..<14).map { "Paragraph \($0 + 1). " + String(repeating: paragraph, count: 3) }.joined(separator: "\n\n")
                world.append(rebuildAssistant("ta\(index)", body, at: at))
            }
        }
        return world
    }

    init() throws {
        roster = try rebuildRoster()
        links = BotLinks(connection: roster.connection)
    }

    private func newModel() -> ChatModel {
        let row = BotRow(
            name: rebuildBotName, isDefault: false, isPrimary: false, isPinned: false, displayName: "Scout", conversationID: nil,
            preview: ClassifiedPreview(kind: .plain, text: ""), lastActive: nil,
            spec: BotAvatarSpec(name: rebuildBotName, uiMeta: nil, photo: nil), accent: nil, usesPrimaryLook: false, sessionIDs: []
        )
        return ChatModel(bot: row, links: links, roster: roster)
    }

    func open() async throws -> FirstLayoutOpen {
        let model = newModel()
        let scroll = ChatScrollController()
        let recorder = FirstLayoutRecorder()
        let clock = ContinuousClock()
        let start = clock.now
        func milliseconds() -> Int { Int(start.duration(to: clock.now) / .milliseconds(1)) }
        scroll.sampleSink = { recorder.record($0, at: milliseconds()) }
        scroll.rowSink = { recorder.recordRow($0, $1) }
        let host = MacChatBenchHost(
            root: MacChatBenchEnvironment(model: model).surface(draft: MacChatBenchDraft(), scroll: scroll), size: MacChatBench.pane
        )
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(20))
        version += 1
        model.apply(world.snapshot(version: version))
        for _ in 0..<Self.frames {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            recorder.rows(model.windowRows.count)
        }
        recorder.finish()
        model.stop()
        return FirstLayoutOpen(
            report: recorder.meter.report(atMilliseconds: milliseconds()), maxContent: recorder.maxContent, rowsAfterData: model.rows.count,
            largestFirstRow: recorder.firstRowHeights.values.max() ?? 0, sustainedPastEnd: recorder.sustained, worstSample: recorder.worstSample
        )
    }
}

@MainActor
@Suite("Mac chat first layout", .serialized)
struct MacChatFirstLayoutTests {
    static let opens = 10
    static let overshootLimit = 1.3
    static let settleLimitMilliseconds = 1000
    static let pastEndLimit = 8.0

    @Test("opening a 160 row chat ten times keeps the content within 1.3x of its settled height, settles in a second, leaves no blank space")
    func openKeepsTheContentNearItsSettledHeight() async throws {
        let stage = try FirstLayoutStage()
        for number in 1...Self.opens {
            let open = try await stage.open()
            print("FIRSTLAYOUT open \(number): \(open.line)")
            let context = Comment(rawValue: "open \(number): \(open.line)")
            #expect(open.rowsAfterData > 0, context)
            #expect(open.maxContent <= open.report.settledContent * Self.overshootLimit, context)
            #expect(open.report.settleMilliseconds < Self.settleLimitMilliseconds, context)
            #expect(open.sustainedPastEnd <= FirstLayoutRecorder.pastEndLimit, context)
            #expect(open.report.rowsHitZero == 0, context)
        }
        let cache = stage.roster.connection.cache
        cache.drain()
        let file = cache.fileURL(name: ChatRowHeightFile.cacheName(forBot: rebuildBotName), account: stage.roster.connection.accountKey)
        #expect(FileManager.default.fileExists(atPath: file.path), "the measured row heights were never written to disk")
    }
}
#endif
