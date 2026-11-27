import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Testing

private let quickReconnect = ReconnectPolicy(initialDelay: .milliseconds(50), maximumDelay: .milliseconds(200))

private func poll(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let stuckPending: JSONValue = [
    ["admission_id": "a-lost", "status": "unknown", "input_id": "i1", "text": "lost", "execution_generation": 3],
    ["admission_id": "a-next", "status": "queued", "input_id": "i2", "text": "follower", "execution_generation": 3],
    ["admission_id": "a-bare", "status": "unknown", "input_id": "i3", "text": "no generation"],
]

private func stuckResume(_ script: TimelineScript) {
    script.override("session.resume") { _ in
        .result([
            "session_id": .string(TimelineScript.sessionID),
            "messages": [],
            "running": false,
            "replay_epoch": .string(TimelineScript.epoch),
            "last_sequence": 1,
            "execution_generation": 3,
            "pending": stuckPending,
            "prompts": [],
        ])
    }
}

private func refusal(_ reason: String) -> FakeGateway.Reply {
    .failure(RPCError(code: 4001, message: reason, data: ["reason": .string(reason)]))
}

@Suite("Unknown admission release", .serialized)
struct UnknownAdmissionTests {
    @Test func aStuckAdmissionIsReleasedOnceWithTheProfileScopedParams() async throws {
        let script = TimelineScript(entries: entries(1...4))
        stuckResume(script)
        script.override("prompt.resolve_unknown") { _ in
            .result(["admission_id": "a-lost", "status": "terminal", "outcome": "discarded"])
        }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let session = ChatSession(profile: "bot", connector: script.connector(gateway.url), reconnectPolicy: quickReconnect)
        try await session.start()
        #expect(await poll { script.count("prompt.resolve_unknown") >= 1 })
        try await Task.sleep(for: .milliseconds(200))

        let calls = script.calls("prompt.resolve_unknown")
        #expect(calls.count == 1)
        let params = try #require(calls.first?.objectValue)
        #expect(Set(params.keys) == ["profile", "session_id", "admission_id", "execution_generation"])
        #expect(params["profile"]?.stringValue == "bot")
        #expect(params["session_id"]?.stringValue == TimelineScript.sessionID)
        #expect(params["admission_id"]?.stringValue == "a-lost")
        #expect(params["execution_generation"]?.intValue == 3)
        await session.close()
    }

    @Test func overlappingResumesNeverDoubleCallAndAnAlreadyResolvedRefusalIsFinal() async throws {
        let script = TimelineScript(entries: entries(1...4))
        stuckResume(script)
        script.override("prompt.resolve_unknown") { _ in .delayed(.milliseconds(300), ["status": "terminal"]) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let session = ChatSession(profile: "bot", connector: script.connector(gateway.url), reconnectPolicy: quickReconnect)
        try await session.start()
        gateway.push(script.event("session.info", seq: 2, payload: ["pending": stuckPending]))
        gateway.push(script.event("session.info", seq: 3, payload: ["pending": stuckPending]))
        try await Task.sleep(for: .milliseconds(600))
        #expect(script.count("prompt.resolve_unknown") == 1)
        await session.close()

        let refused = TimelineScript(entries: entries(1...4))
        stuckResume(refused)
        refused.override("prompt.resolve_unknown") { _ in refusal("stale_generation") }
        let second = try await FakeGateway.start(refused.handle)
        defer { second.stop() }
        let again = ChatSession(profile: "bot", connector: refused.connector(second.url), reconnectPolicy: quickReconnect)
        try await again.start()
        #expect(await poll { refused.count("prompt.resolve_unknown") >= 1 })
        second.push(refused.event("session.info", seq: 2, payload: ["pending": stuckPending]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(refused.count("prompt.resolve_unknown") == 1)
        await again.close()
    }
}
