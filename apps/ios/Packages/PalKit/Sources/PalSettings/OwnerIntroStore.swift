import Foundation

public struct OwnerIntroStore {
    public static let keyPrefix = "hermes.owner.intro.dismissed."

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, account: String) {
        self.defaults = defaults
        key = Self.keyPrefix + account
    }

    public var isDismissed: Bool { defaults.bool(forKey: key) }

    public func dismiss() {
        defaults.set(true, forKey: key)
    }
}
