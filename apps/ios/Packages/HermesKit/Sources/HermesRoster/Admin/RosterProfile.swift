import Foundation
import HermesProtocol

public struct BotMeta: Sendable, Equatable {
    public static let namespace = "hermes-bots"
    public static let pinnedKey = "pinned"

    public var fields: [String: JSONValue]
    public var revision: Int?

    public init(fields: [String: JSONValue] = [:], revision: Int? = nil) {
        self.fields = fields
        self.revision = revision
    }

    public var isPinned: Bool { fields[Self.pinnedKey]?.boolValue ?? false }

    public var title: String? {
        fields["title"]?.stringValue
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setting(pinned: Bool) -> [String: JSONValue] {
        var next = fields
        next[Self.pinnedKey] = .bool(pinned)
        return next
    }
}

public struct RosterProfile: Sendable, Equatable {
    public struct Canonical: Sendable, Equatable {
        public var id: String?
        public var resolvedID: String?
        public var preview: String?
        public var lastActive: TimeInterval?
    }

    public var name: String
    public var displayName: String?
    public var isDefault: Bool
    public var isPrimary: Bool
    public var canonical: Canonical?
    public var uiMeta: JSONValue?
    public var uiMetaRevisions: [String: Int]?
    public var hasAvatar: Bool
    public var onboardingPending: Bool

    public init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        displayName = value["display_name"]?.stringValue
        isDefault = value["is_default"]?.boolValue ?? false
        isPrimary = value["is_primary"]?.boolValue ?? false
        hasAvatar = value["has_avatar"]?.boolValue ?? false
        onboardingPending = value["onboarding_pending"]?.boolValue ?? false
        uiMeta = value["ui_meta"]
        uiMetaRevisions = value["ui_meta_revisions"]?.objectValue?.compactMapValues(\.intValue)
        canonical = value["canonical_session"].flatMap { session in
            guard session.objectValue != nil else { return nil }
            return Canonical(
                id: session["id"]?.stringValue,
                resolvedID: session["resolved_id"]?.stringValue,
                preview: session["preview"]?.stringValue,
                lastActive: session["last_active"]?.numberValue
            )
        }
    }

    public var botMeta: BotMeta {
        let fields = uiMeta?[BotMeta.namespace]?.objectValue ?? [:]
        let revision = uiMetaRevisions.map { max(0, $0[BotMeta.namespace] ?? 0) }
        return BotMeta(fields: fields, revision: revision)
    }
}

public struct RosterCapabilities: Sendable, Equatable {
    public var botBirthNotice: Bool
    public var botOnboarding: Bool

    public init(botBirthNotice: Bool = false, botOnboarding: Bool = false) {
        self.botBirthNotice = botBirthNotice
        self.botOnboarding = botOnboarding
    }

    public init(listResult: JSONValue) {
        self.init(
            botBirthNotice: listResult["bot_birth_notice"]?.boolValue ?? false,
            botOnboarding: listResult["bot_onboarding"]?.boolValue ?? false
        )
    }
}

extension JSONValue {
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
