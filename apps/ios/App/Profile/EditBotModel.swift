import Foundation
import PalBotProfile
import PalDesign
import PalProtocol
import Observation

@MainActor
@Observable
final class EditBotModel: Identifiable {
    var name: String
    var look: BotLook
    private(set) var photo: Data?
    private(set) var isSaving = false
    private(set) var failure: String?

    enum PersonaState: Equatable {
        case loading
        case ready
        case failed
    }

    var bio = ""
    var soul = ""
    private(set) var personaState = PersonaState.loading
    private(set) var isWritingDescription = false
    private(set) var describeFailure: String?
    private(set) var offersReplaceDescription = false
    var confirmsReplaceDescription = false
    private var loadedPersona = BotPersona()

    private var original: BotProfileEditSeed
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

    private var personaEdit: BotPersonaEdit { BotPersonaEdit(description: bio, soul: soul) }

    var changedPersonaFields: Set<BotPersonaField> {
        personaState == .ready ? personaEdit.changedFields(from: loadedPersona) : []
    }

    var isBioTooLong: Bool { BotPersonaEdit.normalized(bio).count > BotPersona.maximumDescriptionLength }

    var isSoulInvalid: Bool {
        personaState == .ready && changedPersonaFields.contains(.soul)
            && (soul.count > BotPersona.maximumSoulLength || soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var personaFieldsEnabled: Bool { personaState == .ready && !isSaving }

    var canSave: Bool {
        guard profile != nil, !trimmedName.isEmpty, trimmedName.count <= 60, !isSaving else { return false }
        let personaOK = personaState != .ready || personaEdit.isValid(from: loadedPersona)
        let anyChange = nameChanged || lookChanged || photoChanged || original.needsLook || !changedPersonaFields.isEmpty
        return personaOK && anyChange
    }

    func loadPersona() async {
        guard let profile, personaState != .ready else { return }
        personaState = .loading
        let key = SurfaceKey.screen("persona", bot: profile.name)
        if let cached = await services.surfaces.value(BotPersona.self, key), personaState == .loading {
            adoptPersona(cached)
        }
        do {
            let fresh = try await services.persona(profile.name).load()
            adoptPersona(fresh)
            services.surfaces.persist(fresh, key)
        } catch {
            if personaState != .ready { personaState = .failed }
        }
    }

    private func adoptPersona(_ persona: BotPersona) {
        let untouched = bio == loadedPersona.description && soul == loadedPersona.soul
        loadedPersona = persona
        if untouched {
            bio = persona.description
            soul = persona.soul
        }
        personaState = .ready
    }

    func writeDescription(overwrite: Bool = false) async {
        guard personaState == .ready, !isWritingDescription, let profile else { return }
        isWritingDescription = true
        describeFailure = nil
        offersReplaceDescription = false
        defer { isWritingDescription = false }
        switch await services.persona(profile.name).describeAutomatically(overwrite: overwrite) {
        case .written(let text):
            loadedPersona.description = text
            bio = text
            services.surfaces.persist(loadedPersona, .screen("persona", bot: profile.name))
        case .alreadyDescribed:
            describeFailure = String(localized: "This bot already has a description you wrote.")
            offersReplaceDescription = true
        case .notOwner:
            describeFailure = String(localized: "Only the owner can write a description.")
        case .failed:
            describeFailure = String(localized: "Couldn't write a description. Try again.")
        }
    }

    func save() async -> Bool {
        guard canSave, let profile else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        let looksChanged = lookChanged || photoChanged
        let photoTouched = photoChanged
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
            if looksChanged || original.needsLook {
                try await services.profiles.updateLook(
                    profile.name, shape: look.shapeString, colorHex: look.colorHex, photo: photoChanged ? hasPhoto : nil
                )
            }
        } catch {
            if photoWritten { await restoreOriginalPhoto(profile.name) }
            failure = String(localized: "Couldn't save your changes. Try again.")
            return false
        }
        original = BotProfileEditSeed(name: trimmedName, look: look, photo: photo, needsLook: false)
        await onSaved(looksChanged || photoTouched ? previewSpec : nil, photo, photoTouched)
        return await savePersona(profile.name)
    }

    private func savePersona(_ profileName: String) async -> Bool {
        let fields = changedPersonaFields
        guard !fields.isEmpty else { return true }
        let outcome = await services.persona(profileName).save(personaEdit, changing: fields)
        if outcome.saved.contains(.description) { loadedPersona.description = BotPersonaEdit.normalized(bio) }
        if outcome.saved.contains(.soul) { loadedPersona.soul = soul }
        var messages: [String] = []
        if outcome.failed.contains(.description) {
            bio = loadedPersona.description
            messages.append(String(localized: "Couldn't save what this bot is good at. It still says what it did before."))
        }
        if outcome.failed.contains(.soul) {
            soul = loadedPersona.soul
            messages.append(String(localized: "Couldn't save the personality. It is unchanged."))
        }
        failure = messages.isEmpty ? nil : messages.joined(separator: " ")
        services.surfaces.persist(loadedPersona, .screen("persona", bot: profileName))
        return messages.isEmpty
    }

    private func restoreOriginalPhoto(_ name: String) async {
        if let previous = original.photo {
            try? await services.profiles.setAvatarPhoto(name, png: previous)
        } else {
            try? await services.profiles.clearAvatarPhoto(name)
        }
    }
}
