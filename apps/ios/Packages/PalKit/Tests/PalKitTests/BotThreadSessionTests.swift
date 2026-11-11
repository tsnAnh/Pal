import Foundation
import PalChat
import PalProtocol
import PalTransport
import Synchronization
import Testing

@Suite("Bot thread links on a chat session", .serialized)
struct BotThreadSessionTests {
    private func linksReply(anchor: String, count: Int) -> JSONValue {
        [
            "links": [[
                "anchor_uid": .string(anchor), "thread_id": "bt_x", "exchange_id": "out:aa", "kind": "messaged",
                "covered_uids": [.string(anchor)], "count": .int(count),
                "counterpart": [
                    "key": "local:beta", "is_self": false, "local_profile": "beta", "display_name": "Beta",
                    "handle": "beta", "avatar": ["has_asset": false],
                ],
            ]],
            "truncated": false,
        ]
    }

    private func session(_ gateway: FakeGateway) -> ChatSession {
        ChatSession(profile: "bot", connector: ScriptedConnector(url: gateway.url))
    }

    @Test func linksLoadOnAttachAndRefreshWhenTheLedgerMoves() async throws {
        let script = BotScript()
        let served = Mutex(1)
        script.override("bot.thread.links") { _ in .result(self.linksReply(anchor: "uid-1", count: served.withLock { $0 })) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(gateway)
        try await chat.start()
        try await waitUntil("first links", timeout: .seconds(5)) { await chat.botThreadLinks.first?.count == 1 }
        served.withLock { $0 = 2 }
        gateway.push(["type": "bot_threads.changed", "payload": [:]])
        try await waitUntil("refreshed links", timeout: .seconds(5)) { await chat.botThreadLinks.first?.count == 2 }
        await chat.close()
    }

    @Test func linksRefreshAfterATurnCompletes() async throws {
        let script = BotScript()
        script.override("bot.thread.links") { number in .result(self.linksReply(anchor: "uid-\(number)", count: 1)) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(gateway)
        try await chat.start()
        try await waitUntil("initial links", timeout: .seconds(5)) { await chat.botThreadLinks.first?.anchorUID == "uid-1" }
        script.lastSequence.withLock { $0 = 2 }
        gateway.push(script.event("message.complete", seq: 2, payload: ["text": "done"]))
        try await waitUntil("links after the turn", timeout: .seconds(5)) { script.count("bot.thread.links") >= 2 }
        await chat.close()
    }

    @Test func aGatewayWithoutBotThreadsLeavesTheChatWorking() async throws {
        let script = BotScript()
        script.messages.withLock { $0 = [("user", "hi"), ("assistant", "hello")] }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(gateway)
        try await chat.start()
        try await waitUntil("a links attempt", timeout: .seconds(5)) { script.count("bot.thread.links") >= 1 }
        #expect(await chat.botThreadLinks.isEmpty)
        #expect(await chat.transcript.assistantTexts == ["hello"])
        await chat.close()
    }
}
