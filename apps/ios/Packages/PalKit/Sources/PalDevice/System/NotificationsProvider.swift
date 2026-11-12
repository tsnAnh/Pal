import Foundation
import UserNotifications

enum NotificationLimit {
    static let title = 80
    static let subtitle = 80
    static let body = 240
    static let identifier = 64
    static let botName = 40
}

enum NotificationScope {
    private static let prefix = "pal.bot."

    static func validated(_ identifier: String) throws -> String {
        let allowed = identifier.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45 || $0 == 95 }
        guard !identifier.isEmpty, identifier.count <= NotificationLimit.identifier, allowed else {
            throw DeviceProviderError.invalidArgs("identifier is 1 to \(NotificationLimit.identifier) letters, digits, dots, dashes or underscores.")
        }
        return identifier
    }

    static func botName(_ profile: String) -> String {
        let kept = profile.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
        let name = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "default" : name).prefix(NotificationLimit.botName))
    }

    static func key(profile: String, identifier: String) -> String {
        "\(prefix)\(botName(profile))/\(identifier)"
    }
}

public protocol NotificationCentering: Sendable {
    func add(identifier: String, title: String, subtitle: String, body: String, sound: Bool) async throws
    func remove(identifier: String) async
}

public struct SystemNotificationCenter: NotificationCentering {
    public init() {}

    public func add(identifier: String, title: String, subtitle: String, body: String, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        if sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    public func remove(identifier: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

public struct SystemNotifications: NotificationsProviding {
    private let center: any NotificationCentering

    public init(center: any NotificationCentering = SystemNotificationCenter()) {
        self.center = center
    }

    public func post(_ draft: NotificationDraft) async throws {
        do {
            try await center.add(identifier: draft.identifier, title: draft.title, subtitle: draft.subtitle, body: draft.body, sound: draft.sound)
        } catch {
            throw DeviceProviderError.failed("The notification could not be shown.")
        }
    }

    public func cancel(identifier: String) async throws {
        await center.remove(identifier: identifier)
    }
}
