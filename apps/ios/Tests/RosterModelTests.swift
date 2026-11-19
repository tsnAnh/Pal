import Foundation
import Observation
import PalAuth
import PalClient
import PalDiagnostics
import PalProtocol
import PalREST
import PalRoster
import Synchronization
import Testing

@testable import HermesBots

private struct UnreachableTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

private final class Hits: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@MainActor
private func makeModel() throws -> RosterModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "roster-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (1)")
    let transport = UnreachableTransport()
    let connection = ConnectionModel(
        auth: try AuthSession(store: InMemoryCredentialStore(), transport: transport),
        transport: transport,
        diagnostics: .silent,
        initialBaseURL: "http://roster-model-tests.invalid",
        presence: ReachPresence(identity: identity),
        cache: CacheStore(root: root)
    )
    return RosterModel(connection: connection)
}

private func profile(_ name: String, lastActive: Double? = nil, title: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["name": .string(name)]
    if let lastActive { fields["canonical_session"] = .object(["preview": "hi", "last_active": .number(lastActive)]) }
    if let title { fields["ui_meta"] = .object(["hermes-bots": .object(["title": .string(title)])]) }
    return .object(fields)
}

private func snapshot(_ profiles: [JSONValue], at seconds: TimeInterval = 0) -> RosterSnapshot {
    RosterSnapshot(profiles: profiles, live: [:], receivedAt: Date(timeIntervalSince1970: seconds))
}

private let fourBots = [
    profile("zeta"),
    profile("bot-a", lastActive: 100),
    profile("alpha"),
    profile("bot-b", lastActive: 300),
]

@MainActor
@Suite("Roster model")
struct RosterModelTests {
    @Test func applyingASnapshotPublishesItsBotsNewestFirstThenByName() async throws {
        let model = try makeModel()
        #expect(model.bots.isEmpty)
        await model.apply(snapshot(fourBots))
        #expect(model.bots.map(\.name) == ["bot-b", "bot-a", "alpha", "zeta"])
        #expect(model.bots.map(\.displayName) == ["Bot B", "Bot A", "Alpha", "Zeta"])
        #expect(model.hasContent)
        #expect(model.isLoaded)
    }

    @Test func applyingTheSameSnapshotTwiceNotifiesNobodyTheSecondTime() async throws {
        let model = try makeModel()
        await model.apply(snapshot(fourBots))
        let hits = Hits()
        withObservationTracking(
            { _ = model.bots; _ = model.live; _ = model.capabilities; _ = model.isLoaded },
            onChange: { hits.bump() }
        )
        await model.apply(snapshot(fourBots, at: 3))
        await model.apply(snapshot(fourBots, at: 6))
        #expect(hits.value == 0)
        #expect(model.bots.map(\.name) == ["bot-b", "bot-a", "alpha", "zeta"])
    }

    @Test func aChangedSnapshotPublishesTheNewBotsOnce() async throws {
        let model = try makeModel()
        await model.apply(snapshot(fourBots))
        let hits = Hits()
        withObservationTracking({ _ = model.bots }, onChange: { hits.bump() })
        await model.apply(snapshot(fourBots + [profile("bot-c", lastActive: 200)], at: 3))
        #expect(hits.value == 1)
        #expect(model.bots.map(\.name) == ["bot-b", "bot-c", "bot-a", "alpha", "zeta"])
    }

    @Test func aBotMissingFromTheNextSnapshotIsOmitted() async throws {
        let model = try makeModel()
        await model.apply(snapshot(fourBots))
        await model.apply(snapshot(Array(fourBots.dropLast()), at: 3))
        #expect(model.bots.map(\.name) == ["bot-a", "alpha", "zeta"])
    }

    @Test func aServerTitleShowsAsTheDisplayName() async throws {
        let model = try makeModel()
        await model.apply(snapshot([profile("bot-a", lastActive: 100, title: "Ada"), profile("bot-b", lastActive: 300)]))
        #expect(model.bots.map(\.displayName) == ["Bot B", "Ada"])
    }

    @Test func pinAndHideOverridesShowAtOnceOnTheRows() async throws {
        let model = try makeModel()
        await model.apply(snapshot(fourBots))
        let target = try #require(model.bot(named: "bot-a"))
        #expect(!target.isPinned && !target.isHidden)
        model.setPinned(target, pinned: true)
        model.setHidden(target, hidden: true)
        let row = try #require(model.bot(named: "bot-a"))
        #expect(row.isPinned)
        #expect(row.isHidden)
        #expect(model.bots.count == 4)
        #expect(try #require(model.bot(named: "bot-b")).isPinned == false)
    }
}
