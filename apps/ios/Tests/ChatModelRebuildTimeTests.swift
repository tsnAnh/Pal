import Foundation
import Observation
import PalAuth
import PalClient
import PalDesign
import PalProtocol
import PalREST
import PalRoster
import Synchronization
import Testing

@testable import HermesBots
@testable import PalChat

@MainActor
@Suite("ChatModel rebuild time and arrival")
struct ChatModelRebuildTimeTests {
    @Test("day separators, five minute gaps and the unread divider survive streaming growth")
    func separatorsAndDividers() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let midnight = calendar.startOfDay(for: rebuildAt(0)).addingTimeInterval(24 * 3600)
        var world = RebuildWorld()
        world.append(rebuildUser("u1", "late", at: midnight.addingTimeInterval(-120)))
        world.append(rebuildAssistant("a1", "answer", at: midnight.addingTimeInterval(-60)))
        world.append(rebuildUser("u2", "next day", at: midnight.addingTimeInterval(60)))
        world.append(rebuildAssistant("a2", "typing", streaming: true, at: midnight.addingTimeInterval(80)))
        let harness = try RebuildHarness(lastSeen: midnight.addingTimeInterval(-30), world: world)
        harness.push()
        harness.push()
        let streaming = try #require(harness.model.rows.last)
        #expect(streaming.separator == nil)
        #expect(streaming.showsUnreadDivider)
        let nextDay = try #require(harness.model.rows.first { $0.id == "row-102" })
        #expect(nextDay.separator != nil)
        for index in 0..<8 {
            harness.world.editLast { $0.content = .assistant(text: "typing \(index)", reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
        harness.world.append(rebuildAssistant("a3", "after a long gap", streaming: true, at: midnight.addingTimeInterval(80 + 600)))
        harness.push("gap")
        #expect(harness.model.rows.last?.separator != nil)
        harness.world.editLast { $0.content = .assistant(text: "after a long gap!", reasoning: "", isStreaming: true) }
        harness.push("grow after gap")
        #expect(harness.model.rows.last?.separator != nil)
    }

    @Test("rows without a timestamp keep the arrival time they were first seen with")
    func rowsWithoutTimestamps() throws {
        var world = RebuildWorld()
        world.sessionID = nil
        world.append(rebuildUser("u1", "no stamp"))
        world.append(rebuildAssistant("a1", "streaming", streaming: true))
        let harness = try RebuildHarness(world: world)
        harness.push("no session")
        harness.world.sessionID = "s1"
        harness.push("baseline")
        for index in 0..<6 {
            harness.world.editLast { $0.content = .assistant(text: "streaming \(index)", reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
        harness.world.append(rebuildAssistant("a2", "new unstamped", streaming: true))
        harness.push("new unstamped")
        for index in 0..<4 {
            harness.world.editLast { $0.content = .assistant(text: "new unstamped \(index)", reasoning: "", isStreaming: true) }
            harness.push("grow new \(index)")
        }
    }
}
