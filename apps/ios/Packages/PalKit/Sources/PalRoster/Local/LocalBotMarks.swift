import Foundation

public struct LocalBotMarks {
    public static let unreadKeyPrefix = "hermes.bot.unread."

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, account: String) {
        self.defaults = defaults
        key = Self.unreadKeyPrefix + account
    }

    public var unread: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func markUnread(_ bot: String) {
        write(unread.union([bot]))
    }

    public func markRead(_ bot: String) {
        write(unread.subtracting([bot]))
    }

    public func prune(keeping bots: Set<String>) {
        let current = unread
        let kept = current.intersection(bots)
        if kept != current { write(kept) }
    }

    private func write(_ names: Set<String>) {
        if names.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(names.sorted(), forKey: key)
        }
    }
}
