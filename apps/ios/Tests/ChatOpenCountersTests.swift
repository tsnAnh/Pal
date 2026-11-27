import Foundation
import Testing

@testable import Pal
@testable import PalChat

@MainActor
@Suite("Chat open counters")
struct ChatOpenCountersTests {
    private func transcript(rows count: Int) -> TimelineSnapshot {
        var world = RebuildWorld()
        world.isRunning = false
        for index in 0..<count {
            world.append(rebuildAssistant("a\(index)", "answer \(index)", at: rebuildAt(TimeInterval(index))))
        }
        return world.snapshot(version: 1)
    }

    @Test("a model kept for the session opens with its rows, from the model, with no time at zero rows")
    func reopenedModelCountsAsModel() throws {
        let model = try rebuildChatModel()
        model.start()
        model.apply(transcript(rows: 30))
        model.stop()
        model.start()
        defer { model.stop() }
        #expect(model.openStats.counters == ChatOpenCounters(source: .model, rowsAtFirstPublish: 30, zeroRowsMilliseconds: 0))
    }

    @Test("a new model seeded from the snapshot memory counts as a snapshot")
    func seededModelCountsAsSnapshot() throws {
        let first = try rebuildChatModel()
        first.apply(transcript(rows: 12))
        first.stop()
        let second = ChatModel(bot: first.openedBot, links: first.links, roster: first.roster)
        second.start()
        defer { second.stop() }
        #expect(second.openStats.counters == ChatOpenCounters(source: .snapshot, rowsAtFirstPublish: 12, zeroRowsMilliseconds: 0))
    }

    @Test("a chat with nothing in memory counts the time until its first rows")
    func emptyOpenCountsTimeAtZero() async throws {
        let model = try rebuildChatModel()
        model.start()
        defer { model.stop() }
        try await Task.sleep(for: .milliseconds(120))
        model.apply(transcript(rows: 8))
        let counters = try #require(model.openStats.counters)
        #expect(counters.source == .none)
        #expect(counters.rowsAtFirstPublish == 8)
        #expect(counters.zeroRowsMilliseconds >= 100)
        #expect(counters.message.hasPrefix("open cache=none rowsAtFirstPublish=8 zeroRowsMs="))
    }
}
