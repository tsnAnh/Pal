import Foundation
import PalChat
import Observation

@MainActor
@Observable
final class EmbedConsentStore {
    static let shared = EmbedConsentStore()
    static let defaultsKey = "pal.embed.alwaysAllowed"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var consent: EmbedConsent
    private(set) var onceLoaded: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consent = EmbedConsent(storageValue: defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func permits(_ descriptor: EmbedDescriptor) -> Bool {
        consent.permits(descriptor, onceLoaded: onceLoaded)
    }

    func loadOnce(_ descriptor: EmbedDescriptor) {
        onceLoaded.insert(descriptor.id)
    }

    func allowAlways(_ provider: EmbedProvider) {
        consent.allowAlways(provider)
        defaults.set(consent.storageValue, forKey: Self.defaultsKey)
    }

    func revoke(_ provider: EmbedProvider) {
        consent.revoke(provider)
        defaults.set(consent.storageValue, forKey: Self.defaultsKey)
    }
}
