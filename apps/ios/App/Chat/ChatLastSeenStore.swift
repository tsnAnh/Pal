import Foundation

struct ChatLastSeenStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSeen(for botName: String) -> Date? {
        guard defaults.object(forKey: Self.key(botName)) != nil else { return nil }
        let seconds = defaults.double(forKey: Self.key(botName))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    func record(_ date: Date, for botName: String) {
        guard date > (lastSeen(for: botName) ?? .distantPast) else { return }
        defaults.set(date.timeIntervalSince1970, forKey: Self.key(botName))
    }

    static func key(_ botName: String) -> String {
        "hermes.chat.lastSeen.\(botName)"
    }
}
