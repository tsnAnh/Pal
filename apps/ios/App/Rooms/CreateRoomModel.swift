import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class CreateRoomModel {
    var name = ""
    private(set) var selected: [String] = []
    private(set) var isCreating = false
    private(set) var failure: String?

    private var pendingRoomID: String?
    private var pendingKey: String?

    var canCreate: Bool {
        !isCreating && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RoomRoster.sizeRange.contains(selected.count)
    }

    func toggle(_ profile: String) {
        if let index = selected.firstIndex(of: profile) {
            selected.remove(at: index)
        } else if selected.count < RoomRoster.sizeRange.upperBound {
            selected.append(profile)
        }
    }

    func create(in rooms: RoomsModel, roster: RosterModel) async -> Room? {
        guard canCreate, let service = rooms.service else { return nil }
        let key = ([name] + selected).joined(separator: "\u{1F}")
        if pendingKey != key {
            pendingKey = key
            pendingRoomID = UUID().uuidString.lowercased()
        }
        guard let roomID = pendingRoomID else { return nil }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        let seats = selected.map { RoomRoster.Seat(profile: $0, displayName: roster.bot(named: $0)?.displayName) }
        do {
            let room = try await service.create(
                roomID: roomID, name: name, seats: seats, seatable: rooms.capabilities?.seatableProfiles
            )
            pendingKey = nil
            pendingRoomID = nil
            rooms.apply(room)
            return room
        } catch let error as RoomError {
            failure = Self.message(for: error)
        } catch {
            failure = String(localized: "The group chat could not be created. Try again.")
        }
        return nil
    }

    private static func message(for error: RoomError) -> String {
        switch error {
        case .invalidRoster(.groupSize): String(localized: "Pick two to six bots.")
        case .invalidRoster(.duplicateMember): String(localized: "Each bot can join a group chat only once.")
        case .invalidRoster(.notSeatable): String(localized: "One of these bots can't join a group chat.")
        case .invalidName: String(localized: "Choose a name up to 120 characters.")
        default: String(localized: "The group chat could not be created. Try again.")
        }
    }
}
