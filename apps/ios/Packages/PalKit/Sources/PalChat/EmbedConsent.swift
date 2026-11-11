import Foundation

public struct EmbedConsent: Sendable, Equatable {
    public private(set) var alwaysAllowed: Set<EmbedProvider>

    public init(alwaysAllowed: Set<EmbedProvider> = []) {
        self.alwaysAllowed = alwaysAllowed
    }

    public init(storageValue: [String]) {
        self.alwaysAllowed = Set(storageValue.compactMap(EmbedProvider.init(rawValue:)))
    }

    public var storageValue: [String] {
        alwaysAllowed.map(\.rawValue).sorted()
    }

    public func permits(_ descriptor: EmbedDescriptor, onceLoaded: Set<String>) -> Bool {
        alwaysAllowed.contains(descriptor.provider) || onceLoaded.contains(descriptor.id)
    }

    public mutating func allowAlways(_ provider: EmbedProvider) {
        alwaysAllowed.insert(provider)
    }

    public mutating func revoke(_ provider: EmbedProvider) {
        alwaysAllowed.remove(provider)
    }
}
