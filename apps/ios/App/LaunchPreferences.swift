import Foundation
import HermesDesign

@MainActor
enum LaunchPreferences {
    static let resetArgument = "-hermes-reset-preferences"

    static func applyReset(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        guard arguments.contains(resetArgument) else { return }
        for key in [AppearanceStore.defaultsKey, SettingsDefaults.hapticsKey, SettingsDefaults.pushKey] {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(ChatLastSeenStore.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
