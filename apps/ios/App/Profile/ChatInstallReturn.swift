import Foundation

enum ChatInstallReturn {
    private static let key = "chatInstallReturnBot"

    static func remember(bot: String) {
        UserDefaults.standard.set(bot, forKey: key)
    }

    static func take() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return UserDefaults.standard.string(forKey: key)
    }
}
