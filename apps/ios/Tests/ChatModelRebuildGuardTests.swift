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

@testable import Pal
@testable import PalChat

@MainActor
@Suite("ChatModel rebuild guards")
struct ChatModelRebuildGuardTests {
    @Test("a streaming snapshot with unchanged ids notifies no id, status or find observer")
    func streamingSnapshotNotifiesOnlyTheRows() throws {
        let harness = try RebuildHarness(world: rebuildConversation())
        harness.push()
        harness.push()
        harness.world.editLast { $0.content = .assistant(text: "Hello there", reasoning: "", isStreaming: true) }
        let fired = rebuildNotifications(harness.model) { harness.push("grow") }
        #expect(fired["rowIDs"] == 0)
        #expect(fired["connection"] == 0)
        #expect(fired["isRunning"] == 0)
        #expect(fired["workingStatus"] == 0)
        #expect(fired["hasPendingClarify"] == 0)
        #expect(fired["hasPendingPrompt"] == 0)
        #expect(fired["olderHistory"] == 0)
        #expect(fired["findMatches"] == 0)
        #expect(fired["findPosition"] == 0)
        #expect(fired["rows"] == 1)
        #expect(fired["rowsNewestFirst"] == 1)
        #expect(fired["windowRows"] == 1)
        #expect(fired["windowRowIDs"] == 0)
        #expect(fired["hiddenOlder"] == 0)
    }

    @Test("applying an equal snapshot again notifies nothing")
    func equalSnapshotNotifiesNothing() throws {
        let harness = try RebuildHarness(world: rebuildConversation())
        harness.push()
        harness.push()
        let fired = rebuildNotifications(harness.model) { harness.push("again") }
        #expect(fired.values.reduce(0, +) == 0, "\(fired)")
    }

    @Test("phase updates that keep the connection never rebuild the rows")
    func phaseUpdatesRebuildOnlyWhenTheConnectionChanges() throws {
        let harness = try RebuildHarness(world: rebuildConversation())
        harness.push()
        harness.push()
        harness.phase(.live(lastSequence: 1, replayEpoch: "e"))
        let settled = harness.model.rebuilds
        for sequence in 2...200 { harness.model.applyPhase(.live(lastSequence: sequence, replayEpoch: "e")) }
        #expect(harness.model.rebuilds == settled)
        #expect(harness.model.connection == .live)
        harness.phase(.resyncing)
        #expect(harness.model.rebuilds.full == settled.full + 1)
        for _ in 0..<50 { harness.model.applyPhase(.attaching) }
        #expect(harness.model.rebuilds.full == settled.full + 1)
        harness.phase(.live(lastSequence: 300, replayEpoch: "e"))
        #expect(harness.model.rebuilds.full == settled.full + 2)
    }

    @Test("an unconfirmed bubble reads the same offline and the rows still match a full rebuild")
    func anUnconfirmedBubbleReadsTheSameOffline() throws {
        var world = rebuildConversation()
        world.rows.removeLast()
        world.append(rebuildUser("u3", "pending", delivery: .sending, at: rebuildAt(430)))
        world.append(rebuildAssistant("a3", "typing", streaming: true, at: rebuildAt(440)))
        let harness = try RebuildHarness(world: world)
        harness.push()
        harness.phase(.live(lastSequence: 1, replayEpoch: "e"), "live")
        harness.push("warm")
        func delivery() -> BubbleDelivery? {
            for row in harness.model.rows where row.id == "row-104" {
                if case .user(_, let delivery) = row.kind { return delivery }
            }
            return nil
        }
        #expect(delivery() == .sending)
        harness.phase(.resyncing, "offline")
        #expect(delivery() == .sending)
        harness.world.editLast { $0.content = .assistant(text: "typing more", reasoning: "", isStreaming: true) }
        harness.push("grow offline")
        #expect(delivery() == .sending)
        harness.phase(.live(lastSequence: 9, replayEpoch: "e"), "live again")
        #expect(delivery() == .sending)
    }

    @Test("find results follow the streaming row and stay unwritten when nothing matches")
    func findFollowsStreaming() throws {
        let harness = try RebuildHarness(world: rebuildConversation(streamingText: "word"))
        harness.push()
        harness.push()
        harness.find("word")
        var text = "word"
        for index in 0..<10 {
            text += " word\(index)"
            harness.world.editLast { $0.content = .assistant(text: text, reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
        #expect(harness.model.findMatches.count == 11)
        harness.model.findPrevious()
        harness.oracle.findPrevious()
        harness.assertEquivalent("previous")
        harness.world.editLast { $0.content = .assistant(text: text + " end", reasoning: "", isStreaming: true) }
        harness.push("grow with position kept")
        harness.find("zzz")
        let fired = rebuildNotifications(harness.model) {
            harness.world.editLast { $0.content = .assistant(text: text + " end again", reasoning: "", isStreaming: true) }
            harness.push("no match")
        }
        #expect(fired["findMatches"] == 0)
        #expect(fired["findPosition"] == 0)
    }
}
