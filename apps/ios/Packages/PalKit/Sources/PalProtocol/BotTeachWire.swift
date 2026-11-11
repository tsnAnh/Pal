import Foundation

public struct BotTeachPendingWire: Codable, Sendable, Hashable {
    public var teachID: String
    public var skillName: String
    public var eventCount: Int
    public var truncated: Bool
    public var state: String

    enum CodingKeys: String, CodingKey {
        case teachID = "teach_id"
        case skillName = "skill_name"
        case eventCount = "event_count"
        case truncated
        case state
    }
}

public struct BotTeachStatusWire: Codable, Sendable, Hashable {
    public var available: Bool
    public var reason: String?
    public var maxSeconds: Int
    public var now: Double
    public var recording: Bool
    public var capture: String
    public var ended: String?
    public var teachID: String?
    public var startedAt: Double?
    public var deadlineAt: Double?
    public var eventCount: Int
    public var truncated: Bool
    public var pending: BotTeachPendingWire?

    enum CodingKeys: String, CodingKey {
        case available
        case reason
        case maxSeconds = "max_seconds"
        case now
        case recording
        case capture
        case ended
        case teachID = "teach_id"
        case startedAt = "started_at"
        case deadlineAt = "deadline_at"
        case eventCount = "event_count"
        case truncated
        case pending
    }
}

public struct BotTeachStopWire: Codable, Sendable, Hashable {
    public var empty: Bool
    public var reason: String?
    public var teachID: String?
    public var skillName: String?
    public var eventCount: Int?
    public var truncated: Bool?
    public var prompt: String?

    enum CodingKeys: String, CodingKey {
        case empty
        case reason
        case teachID = "teach_id"
        case skillName = "skill_name"
        case eventCount = "event_count"
        case truncated
        case prompt
    }
}

public struct BotTeachPromptWire: Codable, Sendable, Hashable {
    public var prompt: String
}

public struct BotTeachDraftWire: Codable, Sendable, Hashable {
    public var teachID: String
    public var skillName: String
    public var eventCount: Int
    public var truncated: Bool
    public var state: String
    public var content: String?
    public var contentHash: String?
    public var extraFiles: [String]

    enum CodingKeys: String, CodingKey {
        case teachID = "teach_id"
        case skillName = "skill_name"
        case eventCount = "event_count"
        case truncated
        case state
        case content
        case contentHash = "content_hash"
        case extraFiles = "extra_files"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teachID = try container.decode(String.self, forKey: .teachID)
        skillName = try container.decode(String.self, forKey: .skillName)
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        state = try container.decode(String.self, forKey: .state)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        extraFiles = try container.decodeIfPresent([String].self, forKey: .extraFiles) ?? []
    }
}

public struct BotTeachApproveWire: Codable, Sendable, Hashable {
    public var teachID: String
    public var skillName: String
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case teachID = "teach_id"
        case skillName = "skill_name"
        case enabled
    }
}

public struct BotTeachDiscardWire: Codable, Sendable, Hashable {
    public var teachID: String
    public var discarded: Bool

    enum CodingKeys: String, CodingKey {
        case teachID = "teach_id"
        case discarded
    }
}
