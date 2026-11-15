import Foundation

public enum TimelineWire {
    public static let capability = "session-timeline-v1"
    public static let pageMethod = "session.timeline"
    public static let resumeLimitParam = "timeline_limit"
    public static let beforeParam = "before"
    public static let limitParam = "limit"
    public static let cursorStaleReason = "cursor_stale"
}

public struct TimelineToolWire: Codable, Sendable, Hashable {
    public var callID: String
    public var name: String
    public var args: JSONValue?
    public var result: JSONValue?
    public var summary: String?

    public init(callID: String, name: String, args: JSONValue? = nil, result: JSONValue? = nil, summary: String? = nil) {
        self.callID = callID
        self.name = name
        self.args = args
        self.result = result
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case name
        case args
        case result
        case summary
    }

    public var resultText: String? {
        switch result {
        case .string(let text)?: text
        case nil, .null?: nil
        case let other?: (try? JSONEncoder().encode(other)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

public struct TimelineEntryWire: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable {
        case user
        case assistant
        case notice
    }

    public var id: String
    public var role: Role
    public var text: String
    public var reasoning: String?
    public var timestamp: Double?
    public var displayKind: String?
    public var displayMetadata: JSONValue?
    public var rowID: Int?
    public var turnID: String?
    public var segment: Int?
    public var tools: [TimelineToolWire]

    public init(
        id: String,
        role: Role,
        text: String,
        reasoning: String? = nil,
        timestamp: Double? = nil,
        displayKind: String? = nil,
        displayMetadata: JSONValue? = nil,
        rowID: Int? = nil,
        turnID: String? = nil,
        segment: Int? = nil,
        tools: [TimelineToolWire] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.displayKind = displayKind
        self.displayMetadata = displayMetadata
        self.rowID = rowID
        self.turnID = turnID
        self.segment = segment
        self.tools = tools
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = (try? container.decode(Role.self, forKey: .role)) ?? .notice
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        timestamp = try? container.decodeIfPresent(Double.self, forKey: .timestamp)
        displayKind = try? container.decodeIfPresent(String.self, forKey: .displayKind)
        displayMetadata = try? container.decodeIfPresent(JSONValue.self, forKey: .displayMetadata)
        rowID = try? container.decodeIfPresent(Int.self, forKey: .rowID)
        turnID = try? container.decodeIfPresent(String.self, forKey: .turnID)
        segment = try? container.decodeIfPresent(Int.self, forKey: .segment)
        tools = try container.decodeIfPresent([TimelineToolWire].self, forKey: .tools) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case reasoning
        case timestamp
        case displayKind = "display_kind"
        case displayMetadata = "display_metadata"
        case rowID = "row_id"
        case turnID = "turn_id"
        case segment
        case tools
    }
}

public struct TimelinePageWire: Codable, Sendable, Hashable {
    public var entries: [TimelineEntryWire]
    public var older: String?
    public var revision: String

    public init(entries: [TimelineEntryWire], older: String?, revision: String) {
        self.entries = entries
        self.older = older
        self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([TimelineEntryWire].self, forKey: .entries) ?? []
        older = try container.decodeIfPresent(String.self, forKey: .older)
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case entries
        case older
        case revision
    }
}

public struct TimelineResume: Decodable, Sendable {
    public var snapshot: SessionSnapshot
    public var timeline: TimelinePageWire?

    public init(snapshot: SessionSnapshot, timeline: TimelinePageWire?) {
        self.snapshot = snapshot
        self.timeline = timeline
    }

    public init(from decoder: any Decoder) throws {
        snapshot = try SessionSnapshot(from: decoder)
        timeline = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(TimelinePageWire.self, forKey: .timeline)
    }

    enum CodingKeys: String, CodingKey {
        case timeline
    }
}

public struct LiveMessageIdentity: Decodable, Sendable, Hashable {
    public var messageUID: String?
    public var turnID: String?
    public var segment: Int?

    public init(messageUID: String? = nil, turnID: String? = nil, segment: Int? = nil) {
        self.messageUID = messageUID
        self.turnID = turnID
        self.segment = segment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persisted = try? container.nestedContainer(keyedBy: PersistedTurnKeys.self, forKey: .persistedTurn)
        messageUID = (try? persisted?.decodeIfPresent(String.self, forKey: .finalAssistantMessageUID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .messageUID))
        turnID = try? container.decodeIfPresent(String.self, forKey: .turnID)
        segment = try? container.decodeIfPresent(Int.self, forKey: .segment)
    }

    enum CodingKeys: String, CodingKey {
        case messageUID = "message_uid"
        case turnID = "turn_id"
        case segment
        case persistedTurn = "persisted_turn"
    }

    enum PersistedTurnKeys: String, CodingKey {
        case finalAssistantMessageUID = "final_assistant_message_uid"
    }
}
