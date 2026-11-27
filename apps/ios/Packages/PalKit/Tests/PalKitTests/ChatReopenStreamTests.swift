@testable import PalChat
import Foundation
import PalProtocol
import Synchronization
import Testing

private final class Latest<Value: Sendable>: Sendable {
    let values = Mutex<[Value]>([])
}

private func eventually(_ predicate: @Sendable () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private struct OpenChatList {
    private let rows = Latest<[String]>()
    private let phases = Latest<ChatPhase>()
    private let timeline: Task<Void, Never>
    private let updates: Task<Void, Never>

    init(_ session: ChatSession) {
        let rows = rows
        let phases = phases
        timeline = Task {
            await TimelinePacer.consume(session.timelineSnapshots, apply: { snapshot in
                rows.values.withLock { $0.append(rowTexts(snapshot)) }
            })
        }
        updates = Task {
            for await update in session.updates {
                if case .phase(let phase) = update { phases.values.withLock { $0.append(phase) } }
            }
        }
    }

    func shows(_ text: String) async -> Bool {
        let rows = rows
        return await eventually { rows.values.withLock { $0.last?.contains(text) == true } }
    }

    func sawReattach() async -> Bool {
        let phases = phases
        return await eventually { phases.values.withLock { $0.contains(.attaching) } }
    }

    func close() async {
        timeline.cancel()
        updates.cancel()
        await timeline.value
        await updates.value
    }
}

private struct ReopenedChat {
    let script: TimelineScript
    let gateway: FakeGateway
    let session: ChatSession
    let list: OpenChatList

    static func make() async throws -> ReopenedChat {
        let script = TimelineScript(entries: entries(1...4))
        let gateway = try await FakeGateway.start(script.handle)
        let hub = SessionHub(profile: "bot", connector: script.connector(gateway.url), pool: WarmSessionPool())
        let session = await hub.acquire()
        try await session.start()
        let left = OpenChatList(session)
        #expect(await left.shows("m4"))
        await left.close()
        await hub.release(session)
        let again = await hub.acquire()
        #expect(again === session)
        return ReopenedChat(script: script, gateway: gateway, session: again, list: OpenChatList(again))
    }

    func finish() async {
        await list.close()
        await session.close()
        gateway.stop()
    }
}

@Suite struct ChatReopenStreamTests {
    @Test func aReopenedChatShowsAReplyFromAnotherSurfaceWithoutAnotherSwitch() async throws {
        let chat = try await ReopenedChat.make()
        chat.script.append([TimelineEntryWire(id: "x1", role: .assistant, text: "sent from another surface", turnID: "t9", segment: 0)])
        chat.gateway.push(chat.script.event("message.start", seq: 2, payload: ["turn_id": "t9"]))
        chat.gateway.push(chat.script.event(
            "message.complete", seq: 3, payload: ["text": "sent from another surface", "turn_id": "t9", "message_uid": "x1"]
        ))
        #expect(await chat.list.shows("sent from another surface"))
        await chat.finish()
    }

    @Test func aReopenedChatStillHearsThatItsConnectionDropped() async throws {
        let chat = try await ReopenedChat.make()
        chat.gateway.dropAll()
        #expect(await chat.list.sawReattach())
        await chat.finish()
    }
}
