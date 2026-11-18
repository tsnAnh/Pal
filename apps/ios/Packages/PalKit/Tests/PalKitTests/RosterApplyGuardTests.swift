import Foundation
import Observation
import PalProtocol
import PalRoster
import Synchronization
import Testing

@Observable
private final class Probe {
    var items: [Int] = [1, 2]
    var flag = false
}

@Observable
private final class MirrorModel {
    private(set) var live: [String: BotLiveState] = [:]
    private(set) var capabilities = RosterCapabilities()
    private(set) var rows: [String] = []
    @ObservationIgnored private(set) var rebuilds = 0
    @ObservationIgnored private var last: RosterSnapshot?

    func apply(_ snapshot: RosterSnapshot) {
        let change = RosterSnapshotChange(from: last, to: snapshot)
        guard !change.isEmpty else { return }
        assignIfChanged(\.live, snapshot.live)
        assignIfChanged(\.capabilities, snapshot.capabilities)
        if change.profiles {
            rebuilds += 1
            assignIfChanged(\.rows, snapshot.profiles.compactMap { $0["name"]?.stringValue })
        }
        last = snapshot
    }
}

private final class Hits: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private func snapshot(
    names: [String] = ["a", "b"],
    live: [String: BotLiveState] = [:],
    capabilities: RosterCapabilities = RosterCapabilities(),
    at date: Date = Date(timeIntervalSince1970: 0)
) -> RosterSnapshot {
    RosterSnapshot(
        profiles: names.map { .object(["name": .string($0), "canonical_session": .object(["preview": "hi"])]) },
        live: live,
        receivedAt: date,
        capabilities: capabilities
    )
}

@Suite("Roster apply guard")
struct RosterApplyGuardTests {
    @Test func assigningAnEqualValueNotifiesNobodyAndAChangeNotifiesOnce() {
        let probe = Probe()
        let hits = Hits()
        withObservationTracking({ _ = probe.items; _ = probe.flag }, onChange: { hits.bump() })
        #expect(probe.assignIfChanged(\.items, [1, 2]) == false)
        #expect(probe.assignIfChanged(\.flag, false) == false)
        #expect(hits.value == 0)
        #expect(probe.assignIfChanged(\.items, [3]) == true)
        #expect(hits.value == 1)
        #expect(probe.items == [3])
        #expect(probe.flag == false)
    }

    @Test func forceWritesAnEqualValue() {
        let probe = Probe()
        let hits = Hits()
        withObservationTracking({ _ = probe.flag }, onChange: { hits.bump() })
        #expect(probe.assignIfChanged(\.flag, false, force: true) == true)
        #expect(hits.value == 1)
    }

    @Test func applyingTheSameSnapshotTwiceCausesZeroNotificationsAndOneRebuild() {
        let model = MirrorModel()
        let working = ["a": BotLiveState(sessions: [.working])]
        model.apply(snapshot(live: working))
        let hits = Hits()
        withObservationTracking({ _ = model.live; _ = model.capabilities; _ = model.rows }, onChange: { hits.bump() })
        model.apply(snapshot(live: working, at: Date(timeIntervalSince1970: 3)))
        model.apply(snapshot(live: working, at: Date(timeIntervalSince1970: 6)))
        #expect(hits.value == 0)
        #expect(model.rebuilds == 1)
    }

    @Test func aChangedFieldChangesOnlyThatField() {
        let model = MirrorModel()
        model.apply(snapshot())
        let liveHits = Hits()
        let capabilityHits = Hits()
        let rowHits = Hits()
        withObservationTracking({ _ = model.live }, onChange: { liveHits.bump() })
        withObservationTracking({ _ = model.capabilities }, onChange: { capabilityHits.bump() })
        withObservationTracking({ _ = model.rows }, onChange: { rowHits.bump() })
        model.apply(snapshot(live: ["a": BotLiveState(sessions: [.working])]))
        #expect(liveHits.value == 1)
        #expect(capabilityHits.value == 0)
        #expect(rowHits.value == 0)
        #expect(model.rebuilds == 1)
    }

    @Test func aChangedProfileListRebuildsAndNotifiesRows() {
        let model = MirrorModel()
        model.apply(snapshot())
        let rowHits = Hits()
        withObservationTracking({ _ = model.rows }, onChange: { rowHits.bump() })
        model.apply(snapshot(names: ["a", "b", "c"]))
        #expect(rowHits.value == 1)
        #expect(model.rows == ["a", "b", "c"])
        #expect(model.rebuilds == 2)
    }

    @Test func snapshotChangeIgnoresReceiptTimeAndNamesTheChangedParts() {
        let base = snapshot(live: ["a": BotLiveState(sessions: [.idle])])
        #expect(RosterSnapshotChange(from: base, to: snapshot(live: ["a": BotLiveState(sessions: [.idle])], at: Date())).isEmpty)
        let first = RosterSnapshotChange(from: nil, to: base)
        #expect(first.profiles && first.live && first.capabilities)
        let moved = RosterSnapshotChange(from: base, to: snapshot(live: ["a": BotLiveState(sessions: [.working])]))
        #expect(moved.live && !moved.profiles && !moved.capabilities)
        let flagged = RosterSnapshotChange(
            from: base, to: snapshot(live: ["a": BotLiveState(sessions: [.idle])], capabilities: RosterCapabilities(botOnboarding: true))
        )
        #expect(flagged.capabilities && !flagged.profiles && !flagged.live)
    }
}

@Suite("Roster refresh schedule")
struct RosterRefreshScheduleTests {
    private func timing() -> RosterFeedTiming {
        RosterFeedTiming(idleRefresh: .seconds(60), busyRefresh: .seconds(3), busyBackoffLimit: .seconds(6))
    }

    private func refetches(over seconds: Int, busy: Bool = true, changing: Bool) -> Int {
        var schedule = RosterRefreshSchedule(timing: timing())
        var lastRefresh = 0
        var count = 0
        for second in 1...seconds where second - lastRefresh >= Int(schedule.interval(busy: busy).components.seconds) {
            lastRefresh = second
            count += 1
            schedule.record(snapshot(names: changing ? ["a\(count)"] : ["a"]))
        }
        return count
    }

    @Test func busyPollWithUnchangedResultsBacksOffToTheLimit() {
        #expect(refetches(over: 60, changing: true) == 20)
        #expect(refetches(over: 60, changing: false) == 11)
    }

    @Test func aChangedResultResetsTheBackoff() {
        var schedule = RosterRefreshSchedule(timing: timing())
        let calm = snapshot()
        schedule.record(calm)
        for _ in 0..<5 { schedule.record(calm) }
        #expect(schedule.interval(busy: true) == .seconds(6))
        schedule.record(snapshot(live: ["a": BotLiveState(sessions: [.working])]))
        #expect(schedule.unchangedStreak == 0)
        #expect(schedule.interval(busy: true) == .seconds(3))
    }

    @Test func idleKeepsItsOwnIntervalAndTheBackoffNeverPassesTheLimit() {
        var schedule = RosterRefreshSchedule(timing: timing())
        for _ in 0..<40 { schedule.record(snapshot()) }
        #expect(schedule.interval(busy: false) == .seconds(60))
        #expect(schedule.interval(busy: true) == .seconds(6))
    }
}

@Suite("Roster display names")
struct RosterDisplayNameTests {
    private func profile(_ name: String, displayName: String? = nil, title: String? = nil) -> RosterProfile {
        var fields: [String: JSONValue] = ["name": .string(name)]
        if let displayName { fields["display_name"] = .string(displayName) }
        if let title { fields["ui_meta"] = .object(["hermes-bots": .object(["title": .string(title)])]) }
        return RosterProfile(.object(fields))!
    }

    @Test func titleWinsThenDisplayNameThenTheHumanisedSlug() {
        #expect(profile("scout", displayName: "Scout Bot", title: "  Ada \n").resolvedDisplayName == "Ada")
        #expect(profile("scout", displayName: " Scout Bot ", title: "   ").resolvedDisplayName == "Scout Bot")
        #expect(profile("my-cool_bot", displayName: "  ").resolvedDisplayName == "My Cool Bot")
        #expect(profile("default").resolvedDisplayName == "Pal")
        #expect(profile("Default", title: "Pal Prime").resolvedDisplayName == "Pal Prime")
    }
}
