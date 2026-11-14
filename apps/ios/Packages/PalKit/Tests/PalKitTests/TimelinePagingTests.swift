import Foundation
import PalChat
import PalClient
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let fastPaging = PagingPolicy(freshness: .milliseconds(300), retryBase: 0.05, retryMax: 0.2)

private func open(
    _ script: TimelineScript,
    paging: PagingPolicy = fastPaging,
    seed: CachedTimeline? = nil
) async throws -> (FakeGateway, ChatSession) {
    let gateway = try await FakeGateway.start(script.handle)
    let session = ChatSession(
        profile: "bot",
        connector: script.connector(gateway.url),
        reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(50), maximumDelay: .milliseconds(200)),
        paging: paging
    )
    if let seed { await session.seed(seed) }
    try await session.start()
    return (gateway, session)
}

private func keys(_ snapshot: TimelineSnapshot) -> [String: RowKey] {
    Dictionary(snapshot.rows.compactMap { row in row.entryID.map { ($0, row.id) } }, uniquingKeysWith: { first, _ in first })
}

@Suite("Chat timeline paging", .serialized)
struct TimelinePagingTests {
    @Test func openShowsTheNewestPageAndPagingFillsHistoryWithoutDuplicatesOrGaps() async throws {
        let script = TimelineScript(entries: entries(1...100))
        script.overlappingPages.withLock { $0 = true }
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        let first = await session.timelineSnapshot
        #expect(rowTexts(first) == (61...100).map { "m\($0)" })
        #expect(first.older == .more)

        let full = try #require(await wantOlderUntil(session) { $0.older == .start })
        #expect(rowTexts(full) == (1...100).map { "m\($0)" })
        #expect(Set(full.rows.map(\.id)).count == full.rows.count)
        let before = keys(first)
        let after = keys(full)
        #expect(before.allSatisfy { after[$0.key] == $0.value })
        await session.close()
    }

    @Test func aPageThatAddsNoVisibleRowsKeepsLoadingFromOneWant() async throws {
        let hidden = (11...60).map {
            TimelineEntryWire(id: "m\($0)", role: .assistant, text: "", tools: [TimelineToolWire(callID: "c\($0)", name: "terminal")])
        }
        let script = TimelineScript(entries: entries(1...10) + hidden + entries(61...100))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        await session.wantOlder()
        let loaded = try #require(await waitForTimeline(session) { rowTexts($0).contains("m10") })
        #expect(rowTexts(loaded) == (1...10).map { "m\($0)" } + (61...100).map { "m\($0)" })
        await session.close()
    }

    @Test func failedPagesRetryWhileWantedAndStopWhenNot() async throws {
        let script = TimelineScript(entries: entries(1...100))
        script.override(TimelineWire.pageMethod) { call in
            call <= 2 ? .failure(RPCError(code: -32603, message: "busy")) : nil
        }
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        let loaded = try #require(await wantOlderUntil(session) { rowTexts($0).contains("m21") })
        #expect(loaded.rows.count == 80)
        #expect(script.count(TimelineWire.pageMethod) >= 3)

        script.override(TimelineWire.pageMethod) { _ in .failure(RPCError(code: -32603, message: "busy")) }
        await session.wantOlder()
        _ = try #require(await waitForTimeline(session) { if case .failed = $0.older { true } else { false } })
        try await Task.sleep(for: .seconds(1))
        let settled = script.count(TimelineWire.pageMethod)
        try await Task.sleep(for: .milliseconds(600))
        #expect(script.count(TimelineWire.pageMethod) == settled)
        #expect(rowTexts(await session.timelineSnapshot).count == 80)
        await session.close()
    }

    @Test(arguments: [true, false])
    func aStreamedReplyKeepsItsRowWhenItSettles(byMessageUID: Bool) async throws {
        let script = TimelineScript(entries: entries(1...4))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        gateway.push(script.event("message.start", seq: 2, payload: ["turn_id": "t1"]))
        gateway.push(script.event("message.delta", seq: 3, payload: ["text": "hello", "turn_id": "t1", "segment": 0, "offset": 0]))
        _ = try #require(await waitForTimeline(session) { $0.isRunning })
        script.append([TimelineEntryWire(
            id: "u5", role: .assistant, text: "hello there", turnID: "t1", segment: 0
        )])
        script.override(TimelineWire.pageMethod) { _ in
            guard case .result(let page) = script.page(before: nil, limit: 40) else { return nil }
            return .delayed(.milliseconds(300), page)
        }
        let identity: JSONValue = byMessageUID ? ["text": "hello there", "turn_id": "t1", "message_uid": "u5"] : ["text": "hello there", "turn_id": "t1"]
        gateway.push(script.event("message.complete", seq: 4, payload: identity))

        let live = try #require(await waitForTimeline(session) { rowTexts($0).contains("hello there") })
        let liveKey = try #require(live.rows.first { row in
            if case .assistant("hello there", _, _) = row.item.content { true } else { false }
        }?.id)
        let settled = try #require(await waitForTimeline(session) { snapshot in snapshot.rows.contains { $0.entryID == "u5" } })
        #expect(settled.rows.first { $0.entryID == "u5" }?.id == liveKey)
        #expect(rowTexts(settled).filter { $0 == "hello there" }.count == 1)
        await session.close()
    }

    @Test func theCacheSeedKeepsRowsAndKeysWhenTheLivePageArrives() async throws {
        let script = TimelineScript(entries: entries(1...100))
        let (gateway, first) = try await open(script)
        defer { gateway.stop() }
        _ = try #require(await wantOlderUntil(first) { $0.older == .start })
        let cache = try #require(await first.cachedTimeline())
        await first.close()
        #expect(cache.entryCount == 100)

        let second = ChatSession(profile: "bot", connector: script.connector(gateway.url), paging: fastPaging)
        await second.seed(cache)
        let seeded = await second.timelineSnapshot
        #expect(rowTexts(seeded) == (1...100).map { "m\($0)" })
        try await second.start()
        let live = await second.timelineSnapshot
        #expect(rowTexts(live) == (1...100).map { "m\($0)" })
        #expect(keys(live) == keys(seeded))
        #expect(live.older == .start)
        await second.close()
    }

    @Test func reconnectAfterManyNewEntriesKeepsPagedInHistory() async throws {
        let script = TimelineScript(entries: entries(1...100))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }
        let full = try #require(await wantOlderUntil(session) { $0.older == .start })

        script.append(entries(101...180))
        gateway.dropAll()
        let caught = try #require(await waitForTimeline(session, timeout: .seconds(10)) { rowTexts($0).last == "m180" })
        #expect(rowTexts(caught) == (1...180).map { "m\($0)" })
        #expect(caught.older == .start)
        let before = keys(full)
        let after = keys(caught)
        #expect(before.allSatisfy { after[$0.key] == $0.value })
        await session.close()
    }

    @Test func aStaleCursorResetsToTheNewestPage() async throws {
        let script = TimelineScript(entries: entries(1...100))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        script.entries.withLock { $0 = entries(201...260) }
        await session.wantOlder()
        let reset = try #require(await waitForTimeline(session) { rowTexts($0).last == "m260" })
        let first = try #require(Int(rowTexts(reset).first?.dropFirst() ?? ""))
        #expect(rowTexts(reset) == (first...260).map { "m\($0)" })
        #expect(first <= 221)
        await session.close()
    }

    @Test func snapshotVersionsNeverRegressWhileStreamingAndPaging() async throws {
        let script = TimelineScript(entries: entries(1...200))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }
        let versions = Mutex<[UInt64]>([])
        let watcher = Task {
            for await snapshot in session.timelineSnapshots { versions.withLock { $0.append(snapshot.version) } }
        }

        gateway.push(script.event("message.start", seq: 2, payload: ["turn_id": "t1"]))
        let streaming = Task {
            for index in 0..<30 {
                gateway.push(script.event("message.delta", seq: 3 + index, payload: [
                    "text": "x", "turn_id": "t1", "segment": 0, "offset": .int(index),
                ]))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let full = try #require(await wantOlderUntil(session) { $0.older == .start })
        await streaming.value
        #expect(rowTexts(full).prefix(200) == ArraySlice((1...200).map { "m\($0)" }))
        await session.close()
        await watcher.value
        let seen = versions.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func aLegacyGatewayLoadsTheWholeHistoryFromResume() async throws {
        let script = TimelineScript(capable: false, entries: entries(1...150))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        let snapshot = await session.timelineSnapshot
        #expect(rowTexts(snapshot) == (1...150).map { "m\($0)" })
        #expect(snapshot.older == .start)
        #expect(script.calls("session.resume").first?[TimelineWire.resumeLimitParam] == nil)
        #expect(script.calls("session.resume").first?["message_limit"] == nil)
        await session.wantOlder()
        try await Task.sleep(for: .milliseconds(100))
        #expect(script.count(TimelineWire.pageMethod) == 0)
        await session.close()
    }

    @Test func revealPagesUntilTheMatchIsLoadedOrHistoryStarts() async throws {
        let script = TimelineScript(entries: entries(1...200))
        let (gateway, session) = try await open(script)
        defer { gateway.stop() }

        let key = try #require(await session.reveal { $0.entryID == "m3" })
        let snapshot = await session.timelineSnapshot
        #expect(snapshot.rows.first { $0.entryID == "m3" }?.id == key)
        #expect(await session.reveal { $0.entryID == "missing" } == nil)
        #expect(await session.timelineSnapshot.older == .start)
        await session.close()
    }
}
