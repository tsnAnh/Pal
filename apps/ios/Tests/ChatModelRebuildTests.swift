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
@Suite("ChatModel rebuild equivalence")
struct ChatModelRebuildTests {
    @Test("growing the streaming row patches only that row and equals a full rebuild at every step")
    func streamingGrowthEqualsFullRebuild() throws {
        let harness = try RebuildHarness(world: rebuildConversation())
        harness.push("first")
        harness.push("warm")
        let before = harness.model.rebuilds
        var text = "Hello"
        for index in 0..<60 {
            text += " word\(index) with `code` and **bold**"
            harness.world.editLast { $0.content = .assistant(text: text, reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
        #expect(harness.model.rebuilds.patched - before.patched == 60)
        #expect(harness.model.rebuilds.full == before.full)
        #expect(harness.model.rows.last?.isStreaming == true)
    }

    @Test("rows appended, a page prepended, edits and deletes all equal a full rebuild")
    func structuralChangesEqualFullRebuild() throws {
        let harness = try RebuildHarness(world: rebuildConversation())
        harness.push("initial")
        harness.push("warm")
        harness.world.editLast { $0.content = .assistant(text: "Hello world", reasoning: "", isStreaming: true) }
        harness.push("grow")
        harness.world.editLast { $0.content = .assistant(text: "Hello world.", reasoning: "", isStreaming: false) }
        harness.push("finished")
        harness.world.append(rebuildUser("u3", "third", at: rebuildAt(900)))
        harness.push("append user")
        harness.world.append(rebuildAssistant("a3", "reply", streaming: true, at: rebuildAt(910)))
        harness.push("append stream")
        harness.world.editLast { $0.content = .assistant(text: "reply plus", reasoning: "", isStreaming: true) }
        harness.push("grow new")
        harness.world.prepend([rebuildUser("o1", "older question", at: rebuildAt(-5000)), rebuildAssistant("o2", "older answer", at: rebuildAt(-4900))])
        harness.push("older page")
        harness.world.editLast { $0.content = .assistant(text: "reply plus more", reasoning: "", isStreaming: true) }
        harness.push("grow after prepend")
        harness.world.rows[2].item.content = .user(text: "edited earlier", delivery: .sent)
        harness.push("edit earlier")
        harness.world.editLast { $0.content = .assistant(text: "reply plus more again", reasoning: "", isStreaming: true) }
        harness.push("grow after edit")
        harness.world.rows.remove(at: 1)
        harness.push("delete")
        harness.world.editLast { $0.content = .assistant(text: "after delete", reasoning: "", isStreaming: true) }
        harness.push("grow after delete")
        harness.world.older = .start
        harness.push("older state")
        #expect(harness.model.olderHistory == .complete)
    }

    @Test("streaming into and out of a hidden or empty row equals a full rebuild")
    func hiddenAndEmptyStreamingRows() throws {
        let harness = try RebuildHarness(world: rebuildConversation(streamingText: ""))
        harness.push("empty")
        harness.push("empty again")
        for (index, text) in ["[SILENT", "[SILENT]", "  [SILENT]  ", "[SILENT] later", "", "back", "back again"].enumerated() {
            harness.world.editLast { $0.content = .assistant(text: text, reasoning: "", isStreaming: true) }
            harness.push("text \(index)")
        }
        #expect(harness.model.rows.last?.id == "row-103")
    }

    @Test("a reasoning-only change and a streaming flag flip equal a full rebuild without moving the rows")
    func reasoningAndFinishFlip() throws {
        let harness = try RebuildHarness(world: rebuildConversation(streamingText: "Same text"))
        harness.push()
        harness.push()
        harness.world.editLast { $0.content = .assistant(text: "Same text", reasoning: "thinking", isStreaming: true) }
        let fired = rebuildNotifications(harness.model) { harness.push("reasoning") }
        #expect(fired["rows"] == 0)
        #expect(fired["rowIDs"] == 0)
        harness.world.editLast { $0.content = .assistant(text: "Same text", reasoning: "thinking", isStreaming: false) }
        harness.push("finish")
        #expect(harness.model.rows.last?.isStreaming == false)
    }

    @Test("answered clarify rows merge per call and stay merged while the reply streams")
    func clarifyAnswersMerge() throws {
        var world = RebuildWorld()
        world.append(rebuildUser("u1", "plan it", at: rebuildAt(0)))
        world.append(rebuildAnswered("c1", 1, "one?", at: rebuildAt(10)))
        world.append(rebuildAnswered("c1", 2, "two?", at: rebuildAt(11)))
        world.append(rebuildAnswered("c2", 1, "three?", at: rebuildAt(12)))
        world.append(rebuildAssistant("a1", "ok", streaming: true, at: rebuildAt(30)))
        let harness = try RebuildHarness(world: world)
        harness.push()
        harness.push()
        #expect(harness.model.rows.count == 4)
        for index in 0..<10 {
            harness.world.editLast { $0.content = .assistant(text: "ok \(index)", reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
        harness.world.rows.insert((50, rebuildAnswered("c2", 2, "four?", at: rebuildAt(13))), at: 4)
        harness.push("late answer")
        #expect(harness.model.rows.count == 4)
    }

    @Test("item ids shared by two rows stay equal to a full rebuild")
    func duplicateItemIDs() throws {
        var world = rebuildConversation()
        world.append(rebuildAssistant("a1", "reused id", streaming: true, at: rebuildAt(500)))
        let harness = try RebuildHarness(world: world)
        harness.push()
        harness.push()
        for index in 0..<5 {
            harness.world.editLast { $0.content = .assistant(text: "reused id \(index)", reasoning: "", isStreaming: true) }
            harness.push("grow \(index)")
        }
    }
}
