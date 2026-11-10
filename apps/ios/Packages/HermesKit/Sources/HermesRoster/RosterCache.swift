import Foundation
import HermesProtocol

public struct RosterCacheEntry: Codable, Sendable, Equatable {
    public var profiles: [JSONValue]
    public var botBirthNotice: Bool
    public var botOnboarding: Bool
    public var photos: [String: Data]
    public var savedAt: Date

    public init(
        profiles: [JSONValue],
        capabilities: RosterCapabilities,
        photos: [String: Data],
        savedAt: Date = Date()
    ) {
        self.profiles = profiles
        botBirthNotice = capabilities.botBirthNotice
        botOnboarding = capabilities.botOnboarding
        self.photos = photos
        self.savedAt = savedAt
    }

    public func hasSameContent(as other: RosterCacheEntry) -> Bool {
        profiles == other.profiles && photos == other.photos
            && botBirthNotice == other.botBirthNotice && botOnboarding == other.botOnboarding
    }

    public var capabilities: RosterCapabilities {
        RosterCapabilities(botBirthNotice: botBirthNotice, botOnboarding: botOnboarding)
    }

    public var snapshot: RosterSnapshot {
        RosterSnapshot(profiles: profiles, live: [:], receivedAt: savedAt, capabilities: capabilities)
    }
}

public enum RosterCache {
    public static let name = "roster"
    public static let maxBots = 200
    public static let maxPhotoBytes = 400_000

    private static let profileKeys: Set<String> = [
        "name", "display_name", "is_default", "is_primary", "has_avatar", "onboarding_pending", "ui_meta_revisions",
    ]
    private static let canonicalKeys: Set<String> = ["id", "resolved_id", "preview", "last_active"]

    public static func entry(from snapshot: RosterSnapshot, photos: [String: Data], savedAt: Date = Date()) -> RosterCacheEntry {
        let profiles = snapshot.profiles.prefix(maxBots).compactMap(sanitized)
        let names = Set(profiles.compactMap { $0["name"]?.stringValue })
        let kept = photos.filter { names.contains($0.key) && $0.value.count <= maxPhotoBytes }
        return RosterCacheEntry(profiles: profiles, capabilities: snapshot.capabilities, photos: kept, savedAt: savedAt)
    }

    static func sanitized(_ profile: JSONValue) -> JSONValue? {
        guard case .object(let fields) = profile, fields["name"]?.stringValue?.isEmpty == false else { return nil }
        var kept = fields.filter { profileKeys.contains($0.key) }
        if let meta = fields["ui_meta"]?.objectValue?[BotMeta.namespace] {
            kept["ui_meta"] = .object([BotMeta.namespace: meta])
        }
        if let canonical = fields["canonical_session"]?.objectValue {
            kept["canonical_session"] = .object(canonical.filter { canonicalKeys.contains($0.key) })
        }
        return .object(kept)
    }
}
