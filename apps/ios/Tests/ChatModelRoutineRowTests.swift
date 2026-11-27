import Foundation
import PalProtocol
import Testing

@testable import Pal
@testable import PalChat

@MainActor
@Suite("A stored routine result reads as an ordinary bot message")
struct ChatModelRoutineRowTests {
    private nonisolated static let body = "3 pull requests are open.\n\n- #411 waits for review"
    private nonisolated static let wrapped = "[Cronjob \"faker-kit-babysit\" output — scheduled job, not the user.]\n\n\(body)"

    private func rows(_ messages: [JSONValue]) throws -> [ChatRow] {
        let object: JSONValue = [
            "session_id": "s1", "running": false, "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1,
            "pending": [], "prompts": [], "messages": .array(messages),
        ]
        var transcript = Transcript()
        transcript.load(try object.decoded(as: SessionSnapshot.self))
        var world = RebuildWorld()
        world.isRunning = false
        for item in transcript.items { world.append(item) }
        let model = try rebuildChatModel()
        model.apply(world.snapshot(version: 1))
        return model.rows
    }

    private func routineRow(_ text: String, status: String = "ok") -> JSONValue {
        [
            "role": "user", "text": .string(text), "row_id": 1, "display_kind": "routine_output",
            "display_metadata": ["job_name": "faker-kit-babysit", "status": .string(status)],
        ]
    }

    @Test("a routine_output row shows as the same plain bubble as a bot reply, with no label and no job name", arguments: [
        (wrapped, "ok"), (body, "ok"), (body, "failed"),
    ])
    func plainBubble(text: String, status: String) throws {
        let reply: JSONValue = ["role": "assistant", "text": .string(Self.body), "row_id": 2]
        let shown = try rows([routineRow(text, status: status), reply])
        #expect(shown.count == 2)
        #expect(shown.first?.kind == shown.last?.kind)
        #expect(shown.first?.searchableText == Self.body)
    }

    @Test("a silent routine result shows nothing")
    func silentResult() throws {
        #expect(try rows([routineRow("[SILENT]")]).isEmpty)
    }
}
