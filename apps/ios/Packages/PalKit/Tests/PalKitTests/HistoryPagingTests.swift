import Foundation
import PalChat
import PalClient
import PalProtocol
import PalTransport
import Testing

private func rows(_ ids: ClosedRange<Int>) -> [WireMessage] {
    ids.map { WireMessage(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "m\($0)", rowID: $0) }
}

private func snapshot(_ messages: [WireMessage], older: Int, sequence: Int) throws -> SessionSnapshot {
    let encoded = try JSONEncoder().encode(messages)
    let wire = try JSONDecoder().decode(JSONValue.self, from: encoded)
    return try JSONValue.object([
        "session_id": "s1", "messages": wire, "older_messages": .int(older), "running": false,
        "replay_epoch": "e1", "last_sequence": .int(sequence), "execution_generation": 1,
        "pending": [], "prompts": [],
    ]).decoded(as: SessionSnapshot.self)
}

@Suite("Chat history paging")
struct HistoryPagingTests {
    @Test func windowedReconcileKeepsOlderRowsAlreadyPagedIn() throws {
        var transcript = Transcript()
        transcript.load(try snapshot(rows(41...100), older: 40, sequence: 1))
        transcript.prependOlder(HistoryPage(messages: rows(1...40), olderMessages: 0))
        #expect(!transcript.hasOlder)

        transcript.requestResync()
        _ = transcript.reconcile(with: try snapshot(rows(43...102), older: 42, sequence: 2))

        #expect(transcript.items.map(\.id) == (1...102).map { "row:\($0)" })
        #expect(!transcript.hasOlder)
        #expect(transcript.oldestRowID == 1)
    }

    @Test func windowedReconcilePastTheLoadedRowsLeavesNoGap() throws {
        var transcript = Transcript()
        transcript.load(try snapshot(rows(41...100), older: 40, sequence: 1))
        transcript.prependOlder(HistoryPage(messages: rows(1...40), olderMessages: 0))

        transcript.requestResync()
        _ = transcript.reconcile(with: try snapshot(rows(201...260), older: 200, sequence: 2))

        #expect(transcript.items.map(\.id) == (201...260).map { "row:\($0)" })
        #expect(transcript.hasOlder)
        #expect(transcript.oldestRowID == 201)
    }

    @Test func prependOlderSkipsRowsAlreadyShown() throws {
        var transcript = Transcript()
        transcript.load(try snapshot(rows(11...20), older: 10, sequence: 1))
        transcript.prependOlder(HistoryPage(messages: rows(5...12), olderMessages: 4))

        #expect(transcript.items.map(\.id) == (5...20).map { "row:\($0)" })
        #expect(transcript.hasOlder)
        #expect(transcript.oldestRowID == 5)
    }

    @Test func resumeOmitsTheLimitWhenTheGatewayDoesNotPage() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connection = try await ScriptedConnector(url: gateway.url).connect()
        let api = SessionAPI(connection: connection, profile: "bot")

        _ = try await api.resume(sessionID: "s1", messageLimit: 60)
        connection.recordNegotiatedRuntime([
            "instance_id": "i", "profile_id": "bot", "authority_epoch": 1,
            "capabilities": [.string(RuntimeDescription.historyPageCapability)],
        ])
        _ = try await api.resume(sessionID: "s1", messageLimit: 60)
        await connection.close()

        let sent = script.calls("session.resume")
        #expect(sent.count == 2)
        #expect(sent.first?["message_limit"] == nil)
        #expect(sent.last?["message_limit"] == .int(60))
    }
}
