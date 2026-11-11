import Foundation
import HermesBotProfile
import HermesDesign
import Observation

@MainActor
@Observable
final class EditBotModel: Identifiable {
    var name: String
    var look: BotLook
    private(set) var photo: Data?
    private(set) var isSaving = false
    private(set) var failure: String?

    private let original: BotProfileEditSeed
    private let profile: BotProfile?
    private let services: BotsServices
    private let onSaved: (BotAvatarSpec?, Data?, Bool) async -> Void

    init(
        profile: BotProfile?,
        seed: BotProfileEditSeed,
        services: BotsServices,
        onSaved: @escaping (BotAvatarSpec?, Data?, Bool) async -> Void
    ) {
        self.profile = profile
        self.original = seed
        self.services = services
        self.onSaved = onSaved
        name = seed.name
        look = seed.look
        photo = seed.photo
    }

    var previewSpec: BotAvatarSpec {
        guard let photo else { return look.spec }
        let meta = BotAvatarMeta(shape: look.shapeString, color: look.colorHex, custom: true, imageKind: .photo)
        return BotAvatarSpec(name: look.seed, meta: meta, photo: photo)
    }

    var hasPhoto: Bool { photo != nil }

    func randomize() {
        var generator = SystemRandomNumberGenerator()
        look = BotLook.random(using: &generator)
        photo = nil
    }

    func pickShape(_ kind: BlobKind) {
        look.kind = kind
        photo = nil
    }

    func removePhoto() {
        photo = nil
    }

    func choosePhoto(_ source: Data?) async {
        guard let source else {
            failure = String(localized: "That photo couldn't be loaded.")
            return
        }
        do {
            photo = try await Task.detached { try AvatarPhoto.prepare(source) }.value
            failure = nil
        } catch AvatarPhoto.Failure.tooLarge {
            failure = String(localized: "That photo is too large.")
        } catch {
            failure = String(localized: "That photo couldn't be prepared.")
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var nameChanged: Bool { trimmedName != original.name }

    var lookChanged: Bool { look != original.look }

    var photoChanged: Bool { photo != original.photo }

    var canSave: Bool {
        profile != nil && !trimmedName.isEmpty && trimmedName.count <= 60 && (nameChanged || lookChanged || photoChanged) && !isSaving
    }

    func save() async -> Bool {
        guard canSave, let profile else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        var photoWritten = false
        do {
            if nameChanged { try await services.profiles.rename(profile, to: trimmedName) }
            if photoChanged {
                if let photo {
                    try await services.profiles.setAvatarPhoto(profile.name, png: photo)
                } else {
                    try await services.profiles.clearAvatarPhoto(profile.name)
                }
                photoWritten = true
            }
            if lookChanged || photoChanged {
                try await services.profiles.updateLook(
                    profile.name, shape: look.shapeString, colorHex: look.colorHex, photo: photoChanged ? hasPhoto : nil
                )
            }
        } catch {
            if photoWritten { await restoreOriginalPhoto(profile.name) }
            failure = String(localized: "Couldn't save your changes. Try again.")
            return false
        }
        await onSaved(lookChanged || photoChanged ? previewSpec : nil, photo, photoChanged)
        return true
    }

    private func restoreOriginalPhoto(_ name: String) async {
        if let previous = original.photo {
            try? await services.profiles.setAvatarPhoto(name, png: previous)
        } else {
            try? await services.profiles.clearAvatarPhoto(name)
        }
    }
}
