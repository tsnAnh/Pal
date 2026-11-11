import Foundation
import HermesBotProfile
import Observation

@MainActor
@Observable
final class MessagingSettingsModel {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable
    }

    enum SaveState: Equatable {
        case saving
        case saved
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var platforms: [MessagingPlatform] = []
    private(set) var restartNeeded = false
    private(set) var saveStates: [String: SaveState] = [:]
    private(set) var fieldErrors: [String: String] = [:]
    var drafts: [String: String] = [:]

    let botName: String
    let displayName: String
    private let services: BotsServices

    init(botName: String, displayName: String, services: BotsServices) {
        self.botName = botName
        self.displayName = displayName
        self.services = services
    }

    func load() async {
        do {
            let snapshot = try await services.messagingSettings.load(profile: botName)
            platforms = snapshot.platforms
            drafts = Self.drafts(for: snapshot.platforms)
            phase = .ready
        } catch is CancellationError {
        } catch {
            phase = .unavailable
        }
    }

    func text(for setting: MessagingSetting) -> String {
        drafts[setting.key] ?? setting.text
    }

    func isDirty(_ platform: MessagingPlatform) -> Bool {
        !changes(in: platform).isEmpty
    }

    func isSaving(_ platform: MessagingPlatform) -> Bool {
        saveStates[platform.id] == .saving
    }

    func save(_ platform: MessagingPlatform) async {
        await submit(platform, enabled: nil, values: changes(in: platform))
    }

    func setEnabled(_ enabled: Bool, in platform: MessagingPlatform) async {
        await submit(platform, enabled: enabled, values: [:])
    }

    private func submit(_ platform: MessagingPlatform, enabled: Bool?, values: [String: [String]]) async {
        guard !isSaving(platform) else { return }
        saveStates[platform.id] = .saving
        clearErrors(in: platform)
        do {
            let result = try await services.messagingSettings.save(profile: botName, platform: platform.id, enabled: enabled, values: values)
            replace(result.platform)
            restartNeeded = restartNeeded || result.restartNeeded
            saveStates[platform.id] = .saved
        } catch is CancellationError {
            saveStates[platform.id] = nil
        } catch MessagingSettingsError.invalid(let fields) {
            fieldErrors.merge(fields) { _, new in new }
            saveStates[platform.id] = .failed(String(localized: "Some settings need a change before they can be saved."))
        } catch {
            saveStates[platform.id] = .failed(String(localized: "Couldn't save. Nothing was changed."))
        }
    }

    private func changes(in platform: MessagingPlatform) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for setting in platform.settings {
            guard let draft = drafts[setting.key] else { continue }
            let values = MessagingSettingsText.values(draft)
            if values != setting.values { result[setting.key] = values }
        }
        return result
    }

    private func clearErrors(in platform: MessagingPlatform) {
        for key in platform.settings.map(\.key) + ["enabled"] { fieldErrors[key] = nil }
    }

    private func replace(_ platform: MessagingPlatform) {
        if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
            platforms[index] = platform
        }
        for setting in platform.settings { drafts[setting.key] = setting.text }
    }

    private static func drafts(for platforms: [MessagingPlatform]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: platforms.flatMap(\.settings).map { ($0.key, $0.text) })
    }
}
