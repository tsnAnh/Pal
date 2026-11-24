#if os(macOS)
import Foundation
import PalChat
import Testing

@testable import Pal

struct MacChatOpenReport: Codable, Equatable {
    var messages: Int
    var modelRows: Int
    var windowRows: Int
    var firstInteractiveMs: Double
    var settledFrames: Int
    var longestStall: MainStallProbe.Stall
    var metrics: ChatOpenMetrics.Snapshot

    var line: String {
        "open \(messages) messages: model rows \(modelRows), window rows \(windowRows), first interactive \(Int(firstInteractiveMs)) ms, "
            + "longest stall \(Int(longestStall.ms)) ms (\(longestStall.label)), rows laid out \(metrics.rowsLaidOut), "
            + "row bodies \(metrics.rowBodies), list bodies \(metrics.listBodies), geometry events \(metrics.geometryEvents), "
            + "position writes \(metrics.positionWrites), frames to settle \(settledFrames)"
    }
}

@MainActor
enum MacChatOpenHarness {
    static func open(messages: Int) throws -> MacChatOpenReport {
        let wasOn = ChatOpenMetrics.isOn
        ChatOpenMetrics.isOn = true
        ChatOpenMetrics.reset()
        defer { ChatOpenMetrics.isOn = wasOn }
        let probe = MainStallProbe()
        probe.start()
        defer { probe.stop() }
        let watchdog = MacChatBenchWatchdog.shared
        watchdog.arm("open \(messages) messages")
        defer { watchdog.disarm() }
        let clock = ContinuousClock()
        let start = clock.now
        let session = MacChatBenchSession(
            environment: try MacChatBenchSession.environment(),
            streamingTail: false,
            messageCount: messages,
            images: true,
            stalls: probe
        )
        defer { session.close() }
        var frames = 0
        while !session.host.isAtNewest, frames < MacChatBench.settleFrames {
            session.host.settle()
            frames += 1
        }
        let interactive = start.duration(to: clock.now).components
        let settled = session.host.settleAtNewest(maxFrames: MacChatBench.settleFrames)
        let report = MacChatOpenReport(
            messages: messages,
            modelRows: session.model.rows.count,
            windowRows: session.model.windowRows.count,
            firstInteractiveMs: Double(interactive.seconds) * 1000 + Double(interactive.attoseconds) / 1e15,
            settledFrames: settled,
            longestStall: probe.longest,
            metrics: ChatOpenMetrics.snapshot
        )
        print(report.line)
        if let directory = MacChatBench.output {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appending(path: "chat-open-\(messages).json"))
        }
        return report
    }
}

@MainActor
@Suite("Mac chat open budget", .serialized)
struct MacChatOpenBudgetTests {
    static let rowMargin = 40
    static let stallBudgetMs = 250.0
    static let positionWriteBudget = 6

    @Test("opening a long chat lays out a bounded window, never stalls the main thread and barely writes the scroll position", arguments: [5_000, 15_000])
    func opensWithinBudget(messages: Int) throws {
        let report = try MacChatOpenHarness.open(messages: messages)
        let context = Comment(rawValue: report.line)
        #expect(report.settledFrames < MacChatBench.settleFrames, context)
        #expect(report.windowRows <= ChatRowWindow.ceiling, context)
        #expect(report.metrics.rowsLaidOut <= ChatRowWindow.size + Self.rowMargin, context)
        #expect(report.longestStall.ms <= Self.stallBudgetMs, context)
        #expect(report.metrics.positionWrites <= Self.positionWriteBudget, context)
    }
}
#endif
