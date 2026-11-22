import Foundation

public struct ChatAudienceMemberWire: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ChatAudienceWire: Decodable, Sendable, Hashable {
    public var policy: ChatAudiencePolicy
    public var members: [ChatAudienceMemberWire]
    public var includeRestricted: Bool
    public var memberTurnsPerHour: Int
    public var revision: Int

    public init(
        policy: ChatAudiencePolicy, members: [ChatAudienceMemberWire], includeRestricted: Bool, memberTurnsPerHour: Int, revision: Int
    ) {
        self.policy = policy
        self.members = members
        self.includeRestricted = includeRestricted
        self.memberTurnsPerHour = memberTurnsPerHour
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case policy, members, revision
        case includeRestricted = "include_restricted", memberTurnsPerHour = "member_turns_per_hour"
    }
}

public struct ChatPersonWire: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var displayName: String
    public var isRestricted: Bool

    public init(id: String, name: String, displayName: String = "", isRestricted: Bool = false) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.isRestricted = isRestricted
    }

    public var shownName: String { displayName.isEmpty ? name : displayName }

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name", isRestricted = "is_restricted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        isRestricted = try container.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
    }
}

public struct ChatPeoplePageWire: Decodable, Sendable, Hashable {
    public var people: [ChatPersonWire]
    public var nextCursor: String?

    public init(people: [ChatPersonWire], nextCursor: String?) {
        self.people = people
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case people
        case nextCursor = "next_cursor"
    }
}

public struct ChatReportDestinationWire: Decodable, Sendable, Hashable {
    public var kind: ChatReportDestinationKind
    public var spaceId: String?
    public var name: String

    public init(kind: ChatReportDestinationKind, spaceId: String? = nil, name: String = "") {
        self.kind = kind
        self.spaceId = spaceId
        self.name = name
    }

    public static let ownerDirectMessages = ChatReportDestinationWire(kind: .ownerDirectMessages)

    public static func space(id: String, name: String) -> ChatReportDestinationWire {
        ChatReportDestinationWire(kind: .space, spaceId: id, name: name)
    }

    enum CodingKeys: String, CodingKey {
        case kind, name
        case spaceId = "space_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ChatReportDestinationKind.self, forKey: .kind)
        spaceId = try container.decodeIfPresent(String.self, forKey: .spaceId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

public struct ChatReportResult: Decodable, Sendable, Hashable {
    public var destination: ChatReportDestinationWire
}

public struct ChatSpaceLeaveResult: Decodable, Sendable, Hashable {
    public var outcome: ChatSpaceLeaveOutcome
}

public struct ChatDeskPersonWire: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String = "") {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

public struct ChatDeskPlaceWire: Decodable, Sendable, Hashable {
    public var conversationId: String
    public var threadTs: String?
    public var label: String

    public init(conversationId: String = "", threadTs: String? = nil, label: String = "") {
        self.conversationId = conversationId
        self.threadTs = threadTs
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case label
        case conversationId = "conversation_id", threadTs = "thread_ts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        threadTs = try container.decodeIfPresent(String.self, forKey: .threadTs)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

public struct ChatDeskRecipientWire: Decodable, Sendable, Hashable {
    public var userId: String?
    public var conversationId: String?
    public var direct: Bool

    public init(userId: String? = nil, conversationId: String? = nil, direct: Bool = false) {
        self.userId = userId
        self.conversationId = conversationId
        self.direct = direct
    }

    enum CodingKeys: String, CodingKey {
        case direct
        case userId = "user_id", conversationId = "conversation_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        direct = try container.decodeIfPresent(Bool.self, forKey: .direct) ?? false
    }
}

public struct ChatDeskItemWire: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ChatDeskItemKind
    public var state: ChatDeskItemState
    public var revision: Int
    public var createdAt: Double
    public var expiresAt: Double
    public var requester: ChatDeskPersonWire?
    public var place: ChatDeskPlaceWire
    public var text: String
    public var why: String?
    public var recipient: ChatDeskRecipientWire?

    public init(
        id: String, kind: ChatDeskItemKind, state: ChatDeskItemState, revision: Int, createdAt: Double, expiresAt: Double,
        requester: ChatDeskPersonWire? = nil, place: ChatDeskPlaceWire = ChatDeskPlaceWire(), text: String, why: String? = nil,
        recipient: ChatDeskRecipientWire? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.revision = revision
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.requester = requester
        self.place = place
        self.text = text
        self.why = why
        self.recipient = recipient
    }

    public var isWaiting: Bool {
        switch state {
        case .open, .approved, .executing: true
        case .posting, .done, .declined, .expired, .cancelled, .failed, .unknown: false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, state, revision, requester, text, why, recipient
        case createdAt = "created_at", expiresAt = "expires_at", place = "where"
    }
}

public struct ChatDeskListResult: Decodable, Sendable, Hashable {
    public var items: [ChatDeskItemWire]
}

public struct ChatDeskDecideResult: Decodable, Sendable, Hashable {
    public var item: ChatDeskItemWire
}

public struct ChatDeskChangedPayload: Decodable, Sendable, Hashable {
    public var item: ChatDeskItemWire
}
