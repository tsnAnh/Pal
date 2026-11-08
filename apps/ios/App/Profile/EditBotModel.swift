import Foundation
import HermesBotProfile
import HermesDesign
import Observation

@MainActor
@Observable
final class EditBotModel: Identifiable {
    var name: String
    var look: BotLook
    private(set) var isSaving = false
    private(set) var failure: String?

    private let original: BotProfileEditSeed
    private let profile: BotProfile?
    private let services: BotsServices
    private let onSaved: (BotAvatarSpec?) async -> Void

    init(
        profile: BotProfile?,
        seed: BotProfileEditSeed,
        services: BotsServices,
        onSaved: @escaping (BotAvatarSpec?) async -> Void
    ) {
        self.profile = profile
        self.original = seed
        self.services = services
        self.onSaved = onSaved
        name = seed.name
        look = seed.look
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var nameChanged: Bool { trimmedName != original.name }

    var lookChanged: Bool { look != original.look }

    var canSave: Bool {
        profile != nil && !trimmedName.isEmpty && trimmedName.count <= 60 && (nameChanged || lookChanged) && !isSaving
    }

    func save() async -> Bool {
        guard canSave, let profile else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            if nameChanged { try await services.profiles.rename(profile, to: trimmedName) }
            if lookChanged { try await services.profiles.updateLook(profile.name, shape: look.shapeString, colorHex: look.colorHex) }
        } catch {
            failure = String(localized: "Couldn't save your changes. Try again.")
            return false
        }
        await onSaved(lookChanged ? look.spec : nil)
        return true
    }
}
