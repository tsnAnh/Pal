import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Connection operation cards", .serialized)
struct ConnectionCardTests {
    private static func request(opID: String = "op-1", seq: Int = 1) -> JSONValue {
        [
            "op_id": .string(opID),
            "seq": .int(seq),
            "deadline_at": .double(Date().timeIntervalSince1970 + 600),
            "timeout_seconds": 600,
            "tool_call_id": "call-1",
            "targets": [[
                "name": "fixture-server", "kind": "mcp", "action": "enable", "state": "pending", "resolved": false,
            ]],
        ]
    }

    private func session(_ connector: ScriptedConnector) -> ChatSession {
        ChatSession(
            profile: "bot",
            connector: connector,
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(20), maximumDelay: .milliseconds(80))
        )
    }

    @Test func connectionRequestReachesAnActivationCardInTheTranscript() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        gateway.push(script.event("connection.request", seq: 2, payload: Self.request()), to: 0)
        let reached = try? await waitUntil("a connection card", timeout: .seconds(3)) {
            await chat.transcript.summary().items.contains { $0.kind == "connection" }
        }
        await chat.close()
        #expect(reached != nil, "connection.request must produce a card in the chat transcript")
    }
}
