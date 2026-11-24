#if os(macOS)
import AppKit
import Foundation
import PalChat
import Testing

@testable import Pal

@MainActor
final class VisibleRowsStage {
    static let rows = 60
    static let blankLimit = 80.0
    static let framesAllowed = 2

    let model: ChatModel
    let host: MacChatBenchHost
    var world: RebuildWorld
    private(set) var lastGeometry: ChatScrollGeometry?
    private(set) var blankStreak = 0
    private(set) var longestBlankStreak = 0
    private(set) var worstGap = 0.0
    private var version: UInt64 = 10

    static func text(_ index: Int, grown: Bool = false) -> String {
        let sentence = "The scheduler picks the next job by priority, then by age, then by owner, and skips any job whose dependencies are not done. "
        let count = grown ? 14 : [1, 2, 4][index % 3]
        return "[\(index)] " + String(repeating: sentence, count: count)
    }

    static func tallTailWorld(count: Int = 160) -> RebuildWorld {
        var world = RebuildWorld()
        world.isRunning = false
        world.rows.removeAll()
        for index in 0..<count {
            let body = index >= count - 8 ? text(index, grown: true) : text(index)
            world.rows.append((UInt64(1_000 + index), rebuildAssistant("a\(index)", body, at: rebuildAt(Double(index) * 90))))
        }
        return world
    }

    static func world(shrinkTail: Bool = false) -> RebuildWorld {
        var world = RebuildWorld()
        world.isRunning = false
        world.rows.removeAll()
        for index in 0..<rows {
            let body = shrinkTail && index >= rows - 6 ? "[\(index)] ok" : text(index)
            world.rows.append((UInt64(1_000 + index), rebuildAssistant("a\(index)", body, at: rebuildAt(Double(index) * 90))))
        }
        return world
    }

    init(opening: RebuildWorld? = nil) async throws {
        let environment = try MacChatBenchSession.environment()
        model = environment.model
        let scroll = ChatScrollController()
        host = MacChatBenchHost(root: environment.surface(draft: MacChatBenchDraft(), scroll: scroll), size: MacChatBench.pane)
        world = opening ?? Self.world()
        scroll.sampleSink = { [unowned self] in lastGeometry = $0.geometry }
        try await Task.sleep(for: .milliseconds(20))
        push()
        try await step(90)
        if opening == nil { resetStreaks() }
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    func resetStreaks() {
        blankStreak = 0
        longestBlankStreak = 0
        worstGap = 0
    }

    func readHistory(points: Double) async throws {
        host.liveScroll(NSScrollView.willStartLiveScrollNotification)
        for _ in 0..<Int(points / 50) {
            host.scroll(by: 50)
            try await step()
        }
        host.liveScroll(NSScrollView.didEndLiveScrollNotification)
        try await step(40)
        resetStreaks()
    }

    func step(_ frames: Int = 1) async throws {
        for _ in 0..<frames {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            let gap = viewportGap()
            worstGap = max(worstGap, gap)
            blankStreak = gap > Self.blankLimit ? blankStreak + 1 : 0
            longestBlankStreak = max(longestBlankStreak, blankStreak)
        }
    }

    var distanceFromNewest: Double {
        guard let scrollView = host.transcriptScrollView, let document = scrollView.documentView else { return .infinity }
        let clip = scrollView.contentView
        let newest = Double(document.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        return abs(newest - Double(clip.bounds.origin.y))
    }

    func rowTops() -> [Int: Double] {
        var tops: [Int: Double] = [:]
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, let tag = OpenJumpProbe.tag(of: text.string) {
                tops[tag] = Double(view.convert(view.bounds, to: host.view).minY)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(host.view)
        return tops
    }

    private func viewportGap() -> Double {
        var spans: [(Double, Double)] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, OpenJumpProbe.tag(of: text.string) != nil {
                let rect = view.convert(view.bounds, to: host.view)
                spans.append((Double(rect.minY), Double(rect.maxY)))
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(host.view)
        let top = 60.0
        let bottom = Double(host.view.bounds.height) - 100
        var cursor = top
        var gap = 0.0
        for (low, high) in spans.sorted(by: { $0.0 < $1.0 }) where high > top && low < bottom {
            gap = max(gap, low - cursor)
            cursor = max(cursor, high)
        }
        return max(gap, bottom - cursor)
    }

    var summary: String {
        String(format: "longest blank streak %d frames, worst blank span %.0f pt", longestBlankStreak, worstGap)
    }
}

@MainActor
@Suite("Mac chat visible rows", .serialized)
struct MacChatVisibleRowsTests {
    private func expectCovered(_ stage: VisibleRowsStage, _ name: String = #function) {
        print("VISIBLE \(name): \(stage.summary)")
        #expect(stage.longestBlankStreak <= VisibleRowsStage.framesAllowed, Comment(rawValue: stage.summary))
    }

    @Test("opening a chat whose newest rows are tall never shows a blank pane")
    func openingATallTail() async throws {
        let stage = try await VisibleRowsStage(opening: VisibleRowsStage.tallTailWorld())
        defer { stage.host.close() }
        expectCovered(stage)
    }

    @Test("rows shrinking below the viewport while pinned leave no blank pane and need no scroll")
    func shrinkWhilePinned() async throws {
        let stage = try await VisibleRowsStage()
        defer { stage.host.close() }
        stage.world = VisibleRowsStage.world(shrinkTail: true)
        stage.push()
        try await stage.step(90)
        expectCovered(stage)
    }

    @Test("rows shrinking below the viewport while reading leave no blank pane and need no scroll")
    func shrinkWhileReading() async throws {
        let stage = try await VisibleRowsStage()
        defer { stage.host.close() }
        try await stage.readHistory(points: 300)
        stage.world = VisibleRowsStage.world(shrinkTail: true)
        stage.push()
        try await stage.step(90)
        expectCovered(stage)
    }

    @Test("rows growing above the viewport while reading leave no blank pane and need no scroll")
    func growAboveWhileReading() async throws {
        let stage = try await VisibleRowsStage()
        defer { stage.host.close() }
        try await stage.readHistory(points: 300)
        for index in 40..<54 {
            let grown = VisibleRowsStage.text(index, grown: true)
            stage.world.rows[index].item = rebuildAssistant("a\(index)", grown, at: rebuildAt(Double(index) * 90))
        }
        stage.push()
        try await stage.step(90)
        expectCovered(stage)
    }
}
#endif
