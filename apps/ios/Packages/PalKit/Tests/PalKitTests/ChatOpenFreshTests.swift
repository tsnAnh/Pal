import Foundation
@testable import PalChat
import PalProtocol
import Synchronization
import Testing

private let fastPaging = PagingPolicy(freshness: .milliseconds(300), retryBase: 0.05, retryMax: 0.2)
private let quickReconnect = ReconnectPolicy(initialDelay: .milliseconds(50), maximumDelay: .milliseconds(200))

private final class MemoryStore: TimelineStore {
    private let slot: Mutex<CachedTimeline?>
    private let writes = Mutex(0)

    init(_ initial: CachedTimeline? = nil) { slot = Mutex(initial) }

    func load() async -> CachedTimeline? { slot.withLock { $0 } }

    func save(_ timeline: CachedTimeline) {
        slot.withLock { $0 = timeline }
        writes.withLock { $0 += 1 }
    }

    var saved: CachedTimeline? { slot.withLock { $0 } }
    var writeCount: Int { writes.withLock { $0 } }
}

private func poll(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func session(
    _ script: TimelineScript, _ gateway: FakeGateway, store: MemoryStore? = nil
) -> ChatSession {
    ChatSession(
        profile: "bot", connector: script.connector(gateway.url), reconnectPolicy: quickReconnect, paging: fastPaging, store: store
    )
}

private func cacheLeftBehind(_ script: TimelineScript, _ gateway: FakeGateway) async throws -> CachedTimeline {
    let first = session(script, gateway)
    try await first.start()
    let cache = try #require(await first.cachedTimeline())
    await first.close()
    return cache
}

private func frame(_ type: String, seq: Int, epoch: String = "e1") -> SessionEventFrame {
    SessionEventFrame(
        event: SessionEvent(type: type, payload: ["text": .string("t\(seq)")]), sessionID: "s1", seq: seq, replayEpoch: epoch
    )
}

@Suite("Chat open freshness", .serialized)
struct ChatOpenFreshTests {
    @Test func theCacheCarriesTheCursorItWasBuiltAt() async throws {
        let script = TimelineScript(entries: entries(1...60))
        script.lastSequence.withLock { $0 = 7 }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let store = MemoryStore()
        let live = session(script, gateway, store: store)
        try await live.start()
        await live.flushCache()

        let saved = try #require(store.saved)
        #expect(saved.cursor == StreamCursor(replayEpoch: "e1", lastSequence: 7))
        #expect(saved.entryCount == 40)
        await live.close()
    }

    @Test func everyAppliedBatchIsPersistedWithoutWaitingForTheLeave() async throws {
        let script = TimelineScript(entries: entries(1...20))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let store = MemoryStore()
        let live = session(script, gateway, store: store)
        try await live.start()

        script.append([TimelineEntryWire(id: "u21", role: .assistant, text: "hello there", turnID: "t1", segment: 0)])
        gateway.push(script.event("message.complete", seq: 5, payload: ["text": "hello there", "turn_id": "t1", "message_uid": "u21"]))
        #expect(await poll { store.saved?.entries.last?.id == "u21" })
        #expect(store.saved?.cursor?.lastSequence == 5)
        await live.close()
    }

    @Test func leavingFlushesAtOnceEvenInsideTheCoalesceWindow() async throws {
        let script = TimelineScript(entries: entries(1...10))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let store = MemoryStore()
        let hub = SessionHub(profile: "bot", connector: script.connector(gateway.url), store: store)
        let held = await hub.acquire()
        try await held.start()
        #expect(store.writeCount == 0)

        await hub.release(held)
        #expect(store.saved?.entries.last?.id == "m10")
    }

    @Test func aCachedOpenHasTheNewestHistoryWithinTheHoldBound() async throws {
        let script = TimelineScript(entries: entries(1...100))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let cache = try await cacheLeftBehind(script, gateway)
        script.append(entries(101...130))
        script.lastSequence.withLock { $0 = 9 }

        let reopened = session(script, gateway, store: MemoryStore(cache))
        await reopened.restore()
        #expect(rowTexts(await reopened.timelineSnapshot).last == "m100")

        let started = ContinuousClock.now
        try await reopened.start()
        let elapsed = started.duration(to: .now)
        #expect(rowTexts(await reopened.timelineSnapshot).last == "m130")
        #expect(elapsed < ChatOpenGate.bound)
        await reopened.close()
    }

    @Test func aCacheNewerThanTheGatewayIsCorrectedDownToTheGatewayHistory() async throws {
        let script = TimelineScript(entries: entries(1...50))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let cache = try await cacheLeftBehind(script, gateway)
        script.entries.withLock { $0 = entries(1...45) }

        let reopened = session(script, gateway, store: MemoryStore(cache))
        await reopened.restore()
        #expect(rowTexts(await reopened.timelineSnapshot).last == "m50")
        try await reopened.start()
        let corrected = await reopened.timelineSnapshot
        #expect(rowTexts(corrected).last == "m45")
        #expect(!rowTexts(corrected).contains("m46"))
        await reopened.close()
    }

    @Test func aCacheFromAnotherReplayEpochOpensOnTheGatewayHistoryAndTakesItsCursor() async throws {
        let script = TimelineScript(entries: entries(1...60))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let stale = try await cacheLeftBehind(script, gateway).withCursor(StreamCursor(replayEpoch: "old", lastSequence: 500))
        script.append(entries(61...70))

        let reopened = session(script, gateway, store: MemoryStore(stale))
        await reopened.restore()
        try await reopened.start()
        #expect(rowTexts(await reopened.timelineSnapshot).last == "m70")
        #expect(await reopened.cachedTimeline()?.cursor == StreamCursor(replayEpoch: "e1", lastSequence: 1))
        await reopened.close()
    }

    @Test func aReconnectUsesTheCursorAndFallsBackToAFullResumeWhenASnapshotIsRequired() async throws {
        let script = TimelineScript(entries: entries(1...20))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        script.override("session.events.since") { _ in
            .result(["events": [], "latest_seq": 9, "replay_epoch": "e1", "snapshot_required": true])
        }
        let live = session(script, gateway)
        try await live.start()
        let resumes = script.count("session.resume")

        script.append(entries(21...30))
        gateway.dropAll()
        _ = try #require(await waitForTimeline(live, timeout: .seconds(10)) { rowTexts($0).last == "m30" })
        #expect(script.count("session.events.since") >= 1)
        #expect(script.count("session.resume") > resumes)
        await live.close()
    }

    @Test func duplicateAndOutOfOrderEventsLeaveTheCursorOnTheNewestSequence() throws {
        var transcript = Transcript()
        let object: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 1]
        _ = transcript.reconcile(with: try object.decoded(as: SessionSnapshot.self))
        #expect(transcript.apply(frame("message.complete", seq: 3)) == .applied)
        #expect(transcript.apply(frame("message.complete", seq: 2)) == .duplicate)
        #expect(transcript.apply(frame("message.complete", seq: 3)) == .duplicate)
        #expect(transcript.cursor == StreamCursor(replayEpoch: "e1", lastSequence: 3))
        #expect(transcript.apply(frame("message.complete", seq: 4, epoch: "e2")) == .resyncRequired(.epochChanged))
    }

    @Test func aWarmSessionIsHandedBackToTheNextHolderWithoutReconnecting() async throws {
        let script = TimelineScript(entries: entries(1...10))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connector = script.connector(gateway.url)
        let hub = SessionHub(profile: "bot", connector: connector, pool: WarmSessionPool(), warmWindow: .seconds(30))
        let first = await hub.acquire()
        try await first.start()
        await hub.release(first)

        let second = await hub.acquire()
        #expect(second === first)
        #expect(connector.attempts == 1)
        #expect(rowTexts(await second.timelineSnapshot).last == "m10")
        await hub.release(second)
        await hub.coolDown()
    }

    @Test func aWarmSessionClosesAfterTheWindowAndTheNextOpenStartsCold() async throws {
        let script = TimelineScript(entries: entries(1...10))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let hub = SessionHub(profile: "bot", connector: script.connector(gateway.url), pool: WarmSessionPool(), warmWindow: .milliseconds(100))
        let first = await hub.acquire()
        try await first.start()
        await hub.release(first)
        try await Task.sleep(for: .milliseconds(400))

        let second = await hub.acquire()
        #expect(second !== first)
        #expect(await first.phase == .detached)
        await hub.release(second)
        await hub.coolDown()
    }

    @Test func theWarmPoolKeepsOnlyTheMostRecentBots() async throws {
        let script = TimelineScript(entries: entries(1...10))
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let pool = WarmSessionPool(limit: 1)
        let older = SessionHub(profile: "a", connector: script.connector(gateway.url), pool: pool, warmWindow: .seconds(30))
        let newer = SessionHub(profile: "b", connector: script.connector(gateway.url), pool: pool, warmWindow: .seconds(30))
        let olderSession = await older.acquire()
        let newerSession = await newer.acquire()
        await older.release(olderSession)
        await newer.release(newerSession)

        #expect(await older.acquire() !== olderSession)
        #expect(await newer.acquire() === newerSession)
    }
}
