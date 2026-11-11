import Foundation
import PalProtocol
import PalRoster
import PalTransport
import Synchronization
import Testing

private final class Box: Sendable {
    let value: Mutex<Int>
    init(_ initial: Int = 0) { value = Mutex(initial) }
}

private final class Collector: Sendable {
    private let items = Mutex<[RosterFeedUpdate]>([])

    func add(_ update: RosterFeedUpdate) { items.withLock { $0.append(update) } }
    var all: [RosterFeedUpdate] { items.withLock { $0 } }
    var links: [GatewayLink] { all.compactMap { if case .link(let link) = $0 { link } else { nil } } }
    var snapshots: [RosterSnapshot] { all.compactMap { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } } }
}

private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func profilesResult(_ names: [String]) -> JSONValue {
    .object(["profiles": .array(names.map { name in
        .object([
            "name": .string(name),
            "canonical_session": .object(["preview": .string("hello \(name)"), "last_active": 1_000]),
        ])
    })])
}

private func activeList(_ status: String) -> JSONValue {
    .object(["sessions": .array([.object(["id": "s", "status": .string(status)])])])
}

private func dialer(_ gateway: FakeGateway, failures: Box? = nil) -> @Sendable () async throws -> GatewayConnection {
    let url = gateway.url
    return {
        if let failures, failures.value.withLock({ remaining in
            defer { if remaining > 0 { remaining -= 1 } }
            return remaining > 0
        }) {
            throw GatewayTransportError.closed(.lost)
        }
        return try await GatewayConnection.dial(url: url, ticket: "t")
    }
}

private func quickTiming() -> RosterFeedTiming {
    RosterFeedTiming(
        backoff: [.milliseconds(20), .milliseconds(40)],
        offlineAfterFailures: 2,
        idleRefresh: .seconds(60),
        busyRefresh: .seconds(60),
        pingInterval: .seconds(60)
    )
}

@Suite("Roster live feed")
struct RosterLiveFeedTests {
    @Test func firstSnapshotCarriesLiveStateForEveryProfile() async throws {
        let gateway = try await FakeGateway.start { method, params, _ in
            switch method {
            case "profiles.list": .result(profilesResult(["a", "b"]))
            case "session.active_list":
                params?["profile"]?.stringValue == "a" ? .result(activeList("working")) : .result(activeList("idle"))
            default: .result([:])
            }
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { !collector.snapshots.isEmpty })
        await feed.stop()
        reader.cancel()
        let snapshot = try #require(collector.snapshots.first)
        #expect(collector.links.first == .connected)
        #expect(snapshot.live["a"]?.sessions == [.working])
        #expect(snapshot.live["b"]?.sessions == [.idle])
        #expect(snapshot.profiles.count == 2)
    }

    @Test func eventBurstDuringARefreshCostsExactlyOneMoreRefresh() async throws {
        let listCalls = Box()
        let gateway = try await FakeGateway.start { method, _, _ in
            switch method {
            case "profiles.list":
                let number = listCalls.value.withLock { $0 += 1; return $0 }
                return number == 2 ? .delayed(.milliseconds(400), profilesResult(["a"])) : .result(profilesResult(["a"]))
            case "session.active_list": return .result(activeList("idle"))
            default: return .result([:])
            }
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { collector.snapshots.count == 1 })

        gateway.push(["type": "sessions.changed", "payload": [:]])
        #expect(await waitUntil { listCalls.value.withLock { $0 } == 2 })
        for _ in 0..<6 {
            gateway.push(["type": "sessions.changed", "payload": [:]])
            gateway.push(["type": "platforms.changed", "payload": [:]])
        }
        #expect(await waitUntil { collector.snapshots.count == 3 })
        try await Task.sleep(for: .milliseconds(600))
        #expect(listCalls.value.withLock { $0 } == 3)
        #expect(collector.snapshots.count == 3)
        await feed.stop()
        reader.cancel()
    }

    @Test func unrelatedEventsDoNotRefresh() async throws {
        let listCalls = Box()
        let gateway = try await FakeGateway.start { method, _, _ in
            if method == "profiles.list" { listCalls.value.withLock { $0 += 1 } }
            return method == "profiles.list" ? .result(profilesResult(["a"])) : .result(activeList("idle"))
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { collector.snapshots.count == 1 })
        gateway.push(["type": "skin.changed", "payload": [:]])
        gateway.push(["type": "cron.changed", "payload": [:]])
        try await Task.sleep(for: .milliseconds(300))
        #expect(listCalls.value.withLock { $0 } == 1)
        await feed.stop()
        reader.cancel()
    }

    @Test func droppedSocketGoesReconnectingThenRecoversWithAFreshSnapshot() async throws {
        let gateway = try await FakeGateway.start { method, _, _ in
            method == "profiles.list" ? .result(profilesResult(["a"])) : .result(activeList("idle"))
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { collector.snapshots.count == 1 })
        gateway.dropAll()
        #expect(await waitUntil { collector.snapshots.count == 2 })
        await feed.stop()
        reader.cancel()
        let links = collector.links
        #expect(links.first == .connected)
        #expect(links.contains(.reconnecting))
        #expect(links.last == .connected)
        #expect(gateway.connectionCount >= 2)
    }

    @Test func repeatedDialFailuresReadOfflineAndRecoveryClearsIt() async throws {
        let gateway = try await FakeGateway.start { method, _, _ in
            method == "profiles.list" ? .result(profilesResult(["a"])) : .result(activeList("idle"))
        }
        defer { gateway.stop() }
        let failures = Box(4)
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway, failures: failures), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { collector.snapshots.count == 1 })
        await feed.stop()
        reader.cancel()
        #expect(collector.links == [.reconnecting, .offline, .connected])
    }

    @Test func nudgeRefreshesAndForcesAnImmediateRetryWhileDisconnected() async throws {
        let listCalls = Box()
        let gateway = try await FakeGateway.start { method, _, _ in
            if method == "profiles.list" { listCalls.value.withLock { $0 += 1 } }
            return method == "profiles.list" ? .result(profilesResult(["a"])) : .result(activeList("idle"))
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { collector.snapshots.count == 1 })
        await feed.nudge()
        #expect(await waitUntil { listCalls.value.withLock { $0 } == 2 })
        await feed.stop()
        reader.cancel()
    }

    @Test func oneProfilesActiveListFailureLeavesOthersIntact() async throws {
        let gateway = try await FakeGateway.start { method, params, _ in
            switch method {
            case "profiles.list": .result(profilesResult(["a", "b"]))
            case "session.active_list":
                params?["profile"]?.stringValue == "a"
                    ? .failure(RPCError(code: 4001, message: "profile_mismatch"))
                    : .result(activeList("waiting"))
            default: .result([:])
            }
        }
        defer { gateway.stop() }
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: quickTiming())
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { !collector.snapshots.isEmpty })
        await feed.stop()
        reader.cancel()
        let snapshot = try #require(collector.snapshots.first)
        #expect(snapshot.live["a"]?.sessions.isEmpty == true)
        #expect(snapshot.live["b"]?.sessions == [.waiting])
        #expect(collector.links.last == .connected)
    }

    @Test func busyProfilesShortenTheSafetyRefresh() async throws {
        let listCalls = Box()
        let gateway = try await FakeGateway.start { method, _, _ in
            if method == "profiles.list" { listCalls.value.withLock { $0 += 1 } }
            return method == "profiles.list" ? .result(profilesResult(["a"])) : .result(activeList("working"))
        }
        defer { gateway.stop() }
        var timing = quickTiming()
        timing.busyRefresh = .milliseconds(150)
        let collector = Collector()
        let feed = RosterLiveFeed(connect: dialer(gateway), timing: timing)
        let reader = Task { for await update in feed.updates { collector.add(update) } }
        await feed.start()
        #expect(await waitUntil { listCalls.value.withLock { $0 } >= 3 })
        await feed.stop()
        reader.cancel()
    }
}
