import Foundation
import PalBotProfile
import PalDesign
import Observation

@MainActor
@Observable
final class BotProfileModel {
    private(set) var profile: BotProfile?
    private(set) var computer: ComputerStatus?
    private(set) var notificationsOn = true
    private(set) var lookOverride: BotAvatarSpec?
    var toast: String?
    var confirmsReplacePrimary = false
    private(set) var editing: EditBotModel?
    private(set) var isSharing = false
    private(set) var isReplacingPrimary = false

    let botName: String
    private let services: BotsServices
    private let roster: RosterModel
    private let sharer: TemplateSharer
    private var notificationsWrite: Task<Void, Never>?

    init(botName: String, services: BotsServices, roster: RosterModel, sharer: TemplateSharer) {
        self.botName = botName
        self.services = services
        self.roster = roster
        self.sharer = sharer
    }

    var row: BotRow? { roster.bot(named: botName) }

    var displayName: String { profile?.displayName ?? row?.displayName ?? botName }

    var isPrimary: Bool { profile?.isPrimary ?? false }

    var isSetupUnfinished: Bool { profile?.isSetupUnfinished ?? false }

    var spec: BotAvatarSpec? { lookOverride ?? row?.spec }

    var routinesText: String? {
        guard let profile else { return nil }
        return String(localized: "\(profile.routinesEnabled) on")
    }

    func load() async {
        async let loadedProfile = try? services.profiles.profile(named: botName)
        async let loadedNotifications = try? services.profiles.notificationsEnabled(for: botName)
        async let loadedComputer = try? services.profiles.computerStatus(for: botName)
        let (profile, notifications, computer) = await (loadedProfile, loadedNotifications, loadedComputer)
        if let profile { self.profile = profile }
        if let notifications, notificationsWrite == nil { notificationsOn = notifications }
        if let computer { self.computer = computer }
    }

    func reloadProfile() async {
        if let profile = try? await services.profiles.profile(named: botName) { self.profile = profile }
    }

    func setNotifications(_ enabled: Bool) {
        guard enabled != notificationsOn else { return }
        let previous = notificationsOn
        notificationsOn = enabled
        let prior = notificationsWrite
        notificationsWrite = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                try await services.profiles.setNotifications(enabled, for: botName)
            } catch is CancellationError {
            } catch {
                notificationsOn = previous
                toast = String(localized: "Couldn't update notifications")
            }
            notificationsWrite = nil
        }
    }

    func copyID() {
        Pasteboard.string = botName
        toast = String(localized: "Copied")
    }

    func replacePrimary() async {
        guard !isReplacingPrimary else { return }
        isReplacingPrimary = true
        defer { isReplacingPrimary = false }
        do {
            try await services.profiles.makePrimary(botName)
            await reloadProfile()
            roster.nudge()
        } catch {
            toast = String(localized: "Couldn't replace the primary bot")
        }
    }

    func shareTemplate() async {
        guard !isSharing else { return }
        isSharing = true
        defer { isSharing = false }
        await sharer.share(botName: botName)
    }

    func saved(look spec: BotAvatarSpec?, photo: Data?, photoChanged: Bool) async {
        if let spec { lookOverride = spec }
        if photoChanged { roster.avatarChanged(botName, photo: photo) }
        await reloadProfile()
        roster.nudge()
    }

    private var currentPhoto: Data? {
        guard case .photo(let avatar)? = spec else { return nil }
        return avatar.data
    }

    func beginEditing() {
        guard let profile else { return }
        let meta = profile.meta
        let seed = BotProfileEditSeed(
            name: displayName,
            look: BotLook(name: botName, shape: meta.shape, color: meta.color),
            photo: currentPhoto,
            needsLook: profile.isSetupUnfinished
        )
        editing = EditBotModel(profile: profile, seed: seed, services: services) { [weak self] spec, photo, photoChanged in
            await self?.saved(look: spec, photo: photo, photoChanged: photoChanged)
        }
    }

    func endEditing() {
        editing = nil
    }
}

struct BotProfileEditSeed: Equatable {
    var name: String
    var look: BotLook
    var photo: Data?
    var needsLook = false
}
