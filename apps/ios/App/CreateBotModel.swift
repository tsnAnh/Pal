import Foundation
import PalDesign
import PalRoster
import Observation

@MainActor
@Observable
final class CreateBotModel {
    enum Failure: Equatable {
        case nameTaken
        case invalidName
        case permissionDenied
        case unavailable
    }

    var name = "" {
        didSet {
            if name.count > BotIdentity.maximumDisplayNameLength { name = String(name.prefix(BotIdentity.maximumDisplayNameLength)) }
            if name != oldValue {
                failure = nil
                identity = BotIdentity(entered: name)
            }
        }
    }

    var shape = BotLookCatalog.defaultShape
    var colorHex = BotLookCatalog.defaultSwatch.hex
    private(set) var isCreating = false
    private(set) var failure: Failure?

    let seed = String(UUID().uuidString.lowercased().prefix(8))

    private(set) var identity = BotIdentity(entered: "")

    var canCreate: Bool { identity.isValid && !isCreating }

    var isNameRejected: Bool { !identity.displayName.isEmpty && !identity.isValid }

    var spec: BotAvatarSpec {
        BotAvatarSpec(
            name: seed,
            meta: BotAvatarMeta(
                shape: BotLookCatalog.shapeString(seed: seed, kind: shape),
                color: colorHex,
                custom: true,
                imageKind: .shape
            )
        )
    }

    func create(in roster: RosterModel) async -> CreatedBot? {
        guard canCreate else { return nil }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        let request = NewBotRequest(name: name, kind: shape.rawValue, colorHex: colorHex, seed: seed)
        do {
            return try await roster.create(request, spec: spec)
        } catch BotAdminError.incomplete(let profile) {
            return CreatedBot(name: profile, displayName: identity.displayName, greetsUnprompted: false)
        } catch let error as BotAdminError {
            failure = Self.failure(for: error)
        } catch {
            failure = .unavailable
        }
        return nil
    }

    private static func failure(for error: BotAdminError) -> Failure {
        switch error {
        case .nameTaken: .nameTaken
        case .invalidName: .invalidName
        case .permissionDenied: .permissionDenied
        default: .unavailable
        }
    }
}
