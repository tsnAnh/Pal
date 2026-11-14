import Foundation
import PalBotProfile
import PalProtocol
import Observation

@MainActor
@Observable
final class RoomsModel {
    static let refreshInterval: Duration = .seconds(5)

    private(set) var rooms: [Room] = []
    private(set) var capabilities: RoomCapabilities?
    var showsCreate = false

    private let services: BotsServices
    private let roster: RosterModel
    private var account: String?
    private var persisted: Snapshot?

    private struct Snapshot: Codable, Sendable, Equatable {
        let rooms: [Room]
        let capabilities: RoomCapabilities
    }

    private static let surfaceKey = SurfaceKey.screen("rooms")

    var surfaces: SurfaceCache { services.surfaces }

    init(services: BotsServices, roster: RosterModel) {
        self.services = services
        self.roster = roster
    }

    var profile: String? {
        roster.bots.first(where: \.isDefault)?.name ?? roster.primaryBot?.name ?? roster.bots.first?.name
    }

    var service: RoomsService? { profile.map(services.rooms) }

    var isAvailable: Bool { capabilities?.driver == true }

    var seatableBots: [BotRow] {
        let seatable = capabilities?.seatableProfiles
        return roster.bots.filter { seatable?.contains($0.name) ?? true }
    }

    var canCreate: Bool { isAvailable && seatableBots.count >= RoomRoster.sizeRange.lowerBound }

    func room(id: String) -> Room? { rooms.first { $0.roomID == id } }

    func run() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func reload() async {
        let key = roster.connection.accountKey
        if key != account {
            reset()
            account = key
        }
        guard let service else { return }
        if capabilities == nil, rooms.isEmpty, let cached = await surfaces.value(Snapshot.self, Self.surfaceKey), capabilities == nil {
            rooms = cached.rooms
            capabilities = cached.capabilities
            persisted = cached
        }
        do {
            let capabilities = try await service.capabilities()
            self.capabilities = capabilities
            guard capabilities.driver else {
                rooms = []
                remember(capabilities)
                return
            }
            rooms = try await service.list().filter { !$0.isDisbanded }
            remember(capabilities)
        } catch {
            if capabilities == nil { rooms = [] }
        }
    }

    private func remember(_ capabilities: RoomCapabilities) {
        let snapshot = Snapshot(rooms: rooms, capabilities: capabilities)
        guard snapshot != persisted else { return }
        persisted = snapshot
        surfaces.persist(snapshot, Self.surfaceKey)
    }

    func reset() {
        rooms = []
        capabilities = nil
        persisted = nil
        showsCreate = false
    }

    func apply(_ room: Room) {
        if let index = rooms.firstIndex(where: { $0.roomID == room.roomID }) {
            rooms[index] = room
        } else {
            rooms.insert(room, at: 0)
        }
    }
}
