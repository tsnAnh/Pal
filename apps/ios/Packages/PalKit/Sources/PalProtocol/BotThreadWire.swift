import Foundation

public struct BotThreadAvatar: Codable, Sendable, Hashable {
    public var hasAsset: Bool
    public var uiMeta: JSONValue?

    public init(hasAsset: Bool = false, uiMeta: JSONValue? = nil) {
        self.hasAsset = hasAsset
        self.uiMeta = uiMeta
    }

    enum CodingKeys: String, CodingKey {
        case hasAsset = "has_asset"
        case uiMeta = "ui_meta"
    }
}

public struct BotThreadParticipant: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var isSelf: Bool
    public var localProfile: String?
    public var displayName: String
    public var handle: String
    public var avatar: BotThreadAvatar

    public var id: String { key }

    public init(
        key: String,
        isSelf: Bool,
        localProfile: String? = nil,
        displayName: String,
        handle: String,
        avatar: BotThreadAvatar = BotThreadAvatar()
    ) {
        self.key = key
        self.isSelf = isSelf
        self.localProfile = localProfile
        self.displayName = displayName
        self.handle = handle
        self.avatar = avatar
    }

    enum CodingKeys: String, CodingKey {
        case key
        case isSelf = "is_self"
        case localProfile = "local_profile"
        case displayName = "display_name"
        case handle
        case avatar
    }
}

public struct BotThreadMessageStatus: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let pending = BotThreadMessageStatus(rawValue: "pending")
    public static let delivered = BotThreadMessageStatus(rawValue: "delivered")
    public static let unknown = BotThreadMessageStatus(rawValue: "unknown")
    public static let answered = BotThreadMessageStatus(rawValue: "answered")
    public static let failed = BotThreadMessageStatus(rawValue: "failed")
}

public struct BotThreadMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var exchangeID: String
    public var senderKey: String
    public var text: String
    public var at: Date
    public var part: String
    public var status: BotThreadMessageStatus
    public var statusText: String?

    public init(
        id: String,
        exchangeID: String,
        senderKey: String,
        text: String,
        at: Date,
        part: String = "message",
        status: BotThreadMessageStatus = .answered,
        statusText: String? = nil
    ) {
        self.id = id
        self.exchangeID = exchangeID
        self.senderKey = senderKey
        self.text = text
        self.at = at
        self.part = part
        self.status = status
        self.statusText = statusText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case exchangeID = "exchange_id"
        case senderKey = "sender_key"
        case text
        case at
        case part
        case status
        case statusText = "status_text"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        exchangeID = try container.decode(String.self, forKey: .exchangeID)
        senderKey = try container.decode(String.self, forKey: .senderKey)
        text = try container.decode(String.self, forKey: .text)
        let stamp = try container.decode(String.self, forKey: .at)
        guard let parsed = BotThreadClock.date(from: stamp) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "Invalid timestamp")
        }
        at = parsed
        part = try container.decode(String.self, forKey: .part)
        status = try container.decode(BotThreadMessageStatus.self, forKey: .status)
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(exchangeID, forKey: .exchangeID)
        try container.encode(senderKey, forKey: .senderKey)
        try container.encode(text, forKey: .text)
        try container.encode(BotThreadClock.string(from: at), forKey: .at)
        try container.encode(part, forKey: .part)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(statusText, forKey: .statusText)
    }

    public var sequence: Int? {
        id.hasPrefix("btm_") ? Int(id.dropFirst(4)) : nil
    }
}

enum BotThreadClock {
    static func date(from text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

public struct BotThreadLink: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case messaged
        case messageFrom = "message_from"
    }

    public var anchorUID: String
    public var threadID: String
    public var exchangeID: String
    public var kind: Kind
    public var counterpart: BotThreadParticipant
    public var coveredUIDs: [String]
    public var count: Int

    public var id: String { anchorUID }

    public init(
        anchorUID: String,
        threadID: String,
        exchangeID: String,
        kind: Kind,
        counterpart: BotThreadParticipant,
        coveredUIDs: [String],
        count: Int
    ) {
        self.anchorUID = anchorUID
        self.threadID = threadID
        self.exchangeID = exchangeID
        self.kind = kind
        self.counterpart = counterpart
        self.coveredUIDs = coveredUIDs
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case anchorUID = "anchor_uid"
        case threadID = "thread_id"
        case exchangeID = "exchange_id"
        case kind
        case counterpart
        case coveredUIDs = "covered_uids"
        case count
    }
}

public struct BotThreadLinksResult: Codable, Sendable, Hashable {
    public var links: [BotThreadLink]
    public var truncated: Bool
}

public struct BotThreadPage: Codable, Sendable, Hashable {
    public var threadID: String
    public var participants: [BotThreadParticipant]
    public var messages: [BotThreadMessage]
    public var focusIndex: Int?
    public var before: Int?
    public var after: Int?
    public var rev: Int
    public var coverage: String
    public var historySince: String?

    public var isOwnSideOnly: Bool { coverage == "own_side" }

    public init(
        threadID: String,
        participants: [BotThreadParticipant],
        messages: [BotThreadMessage],
        focusIndex: Int?,
        before: Int?,
        after: Int?,
        rev: Int,
        coverage: String,
        historySince: String?
    ) {
        self.threadID = threadID
        self.participants = participants
        self.messages = messages
        self.focusIndex = focusIndex
        self.before = before
        self.after = after
        self.rev = rev
        self.coverage = coverage
        self.historySince = historySince
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case participants
        case messages
        case focusIndex = "focus_index"
        case before
        case after
        case rev
        case coverage
        case historySince = "history_since"
    }
}
