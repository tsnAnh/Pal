import Foundation

public struct PushSender: Equatable, Sendable {
    public let profile: String
    public let displayName: String
    public let body: String

    private static let maximumProfileLength = 64

    public init?(userInfo: [AnyHashable: Any], title: String, body: String) {
        guard let profile = userInfo["profile"] as? String, Self.isUsable(profile: profile) else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.profile = profile
        self.displayName = name
        self.body = body
    }

    public static func isUsable(profile: String) -> Bool {
        guard (1...maximumProfileLength).contains(profile.utf8.count) else { return false }
        return profile.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95
        }
    }
}
