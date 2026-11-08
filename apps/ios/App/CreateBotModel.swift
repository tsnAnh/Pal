import HermesDesign
import HermesRoster
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
            if name != oldValue { failure = nil }
        }
    }

    var shape = BotLookCatalog.defaultShape
    var swatch = BotLookCatalog.defaultSwatch
    private(set) var isCreating = false
    private(set) var failure: Failure?

    private static let placeholderSeed = "agent"

    var identity: BotIdentity { BotIdentity(entered: name) }

    var canCreate: Bool { identity.isValid && !isCreating }

    var isNameRejected: Bool { !identity.displayName.isEmpty && !identity.isValid }

    var seed: String { identity.isValid ? identity.slug : Self.placeholderSeed }

    var spec: BotAvatarSpec {
        BotAvatarSpec(
            name: seed,
            meta: BotAvatarMeta(
                shape: BotLookCatalog.shapeString(seed: seed, kind: shape),
                color: swatch.hex,
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
        let request = NewBotRequest(name: name, kind: shape.rawValue, colorHex: swatch.hex)
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
