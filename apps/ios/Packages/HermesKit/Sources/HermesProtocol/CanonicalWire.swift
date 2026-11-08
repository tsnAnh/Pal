import Foundation

public struct SessionRef: Codable, Sendable, Hashable {
    public var profileID: String
    public var sessionID: String

    public init(profileID: String, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case sessionID = "session_id"
    }
}

public struct AdmissionState: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let queued = AdmissionState(rawValue: "queued")
    public static let started = AdmissionState(rawValue: "started")
    public static let unknown = AdmissionState(rawValue: "unknown")
    public static let terminal = AdmissionState(rawValue: "terminal")
}

public struct AdmissionStatus: Codable, Sendable, Hashable {
    public var admissionID: String
    public var ref: SessionRef?
    public var sequence: Int?
    public var status: AdmissionState
    public var outcome: String?
    public var authorityEpoch: Int?
    public var executionGeneration: Int?

    enum CodingKeys: String, CodingKey {
        case admissionID = "admission_id"
        case ref
        case sequence
        case status
        case outcome
        case authorityEpoch = "authority_epoch"
        case executionGeneration = "execution_generation"
    }
}

public struct PendingAdmission: Codable, Sendable, Hashable {
    public var admissionID: String
    public var status: AdmissionState
    public var sequence: Int?
    public var inputID: String?
    public var text: String?
    public var executionGeneration: Int?

    public init(
        admissionID: String,
        status: AdmissionState,
        sequence: Int? = nil,
        inputID: String? = nil,
        text: String? = nil,
        executionGeneration: Int? = nil
    ) {
        self.admissionID = admissionID
        self.status = status
        self.sequence = sequence
        self.inputID = inputID
        self.text = text
        self.executionGeneration = executionGeneration
    }

    enum CodingKeys: String, CodingKey {
        case admissionID = "admission_id"
        case status
        case sequence
        case inputID = "input_id"
        case text
        case executionGeneration = "execution_generation"
    }
}

public struct PendingPrompt: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case clarify
        case approval
    }

    public var kind: Kind
    public var promptID: String
    public var executionGeneration: Int
    public var choices: [String]
    public var question: String?
    public var multiSelect: Bool?
    public var command: String?
    public var description: String?
    public var timeoutSeconds: Int?

    public init(
        kind: Kind,
        promptID: String,
        executionGeneration: Int,
        choices: [String] = [],
        question: String? = nil,
        multiSelect: Bool? = nil,
        command: String? = nil,
        description: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.kind = kind
        self.promptID = promptID
        self.executionGeneration = executionGeneration
        self.choices = choices
        self.question = question
        self.multiSelect = multiSelect
        self.command = command
        self.description = description
        self.timeoutSeconds = timeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        promptID = try container.decode(String.self, forKey: .promptID)
        executionGeneration = try container.decodeIfPresent(Int.self, forKey: .executionGeneration) ?? 0
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        question = try container.decodeIfPresent(String.self, forKey: .question)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case promptID = "prompt_id"
        case executionGeneration = "execution_generation"
        case choices
        case question
        case multiSelect = "multi_select"
        case command
        case description
        case timeoutSeconds = "timeout_s"
    }
}

public struct WireMessage: Codable, Sendable, Hashable {
    public var role: String
    public var text: String?
    public var content: JSONValue?
    public var toolCallID: String?
    public var timestamp: Double?
    public var rowID: Int?
    public var messageUID: String?
    public var displayKind: String?
    public var displayMetadata: JSONValue?
    public var name: String?
    public var reasoning: String?

    enum CodingKeys: String, CodingKey {
        case role
        case text
        case content
        case toolCallID = "tool_call_id"
        case timestamp
        case rowID = "row_id"
        case messageUID = "message_uid"
        case displayKind = "display_kind"
        case displayMetadata = "display_metadata"
        case name
        case reasoning
    }

    public init(role: String, text: String? = nil, rowID: Int? = nil, messageUID: String? = nil) {
        self.role = role
        self.text = text
        self.rowID = rowID
        self.messageUID = messageUID
    }

    public var plainText: String {
        if let text { return text }
        return content?.stringValue ?? ""
    }
}

public struct OpenRequest: Codable, Sendable, Hashable {
    public var id: String
    public var method: String
    public var params: JSONValue?
}

public struct SessionSnapshot: Codable, Sendable, Hashable {
    public var sessionID: String
    public var storedSessionID: String?
    public var messages: [WireMessage]
    public var running: Bool
    public var authorityEpoch: Int?
    public var replayEpoch: String
    public var lastSequence: Int
    public var executionGeneration: Int
    public var pending: [PendingAdmission]
    public var prompts: [PendingPrompt]
    public var openRequests: [OpenRequest]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        storedSessionID = try container.decodeIfPresent(String.self, forKey: .storedSessionID)
        messages = try container.decodeIfPresent([WireMessage].self, forKey: .messages) ?? []
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        authorityEpoch = try container.decodeIfPresent(Int.self, forKey: .authorityEpoch)
        replayEpoch = try container.decode(String.self, forKey: .replayEpoch)
        lastSequence = try container.decodeIfPresent(Int.self, forKey: .lastSequence) ?? 0
        executionGeneration = try container.decodeIfPresent(Int.self, forKey: .executionGeneration) ?? 0
        pending = try container.decodeIfPresent([PendingAdmission].self, forKey: .pending) ?? []
        prompts = try container.decodeIfPresent([PendingPrompt].self, forKey: .prompts) ?? []
        openRequests = try container.decodeIfPresent([OpenRequest].self, forKey: .openRequests) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case storedSessionID = "stored_session_id"
        case messages
        case running
        case authorityEpoch = "authority_epoch"
        case replayEpoch = "replay_epoch"
        case lastSequence = "last_sequence"
        case executionGeneration = "execution_generation"
        case pending
        case prompts
        case openRequests = "open_requests"
    }
}

public struct SessionListRow: Codable, Sendable, Hashable {
    public var sessionID: String
    public var id: String?
    public var title: String
    public var source: String?
    public var startedAt: Double?
    public var messageCount: Int?
    public var running: Bool?
    public var resolvedID: String?
    public var rootTitle: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case id
        case title
        case source
        case startedAt = "started_at"
        case messageCount = "message_count"
        case running
        case resolvedID = "resolved_id"
        case rootTitle = "root_title"
    }
}

public struct SessionListResult: Codable, Sendable, Hashable {
    public var sessions: [SessionListRow]
    public var scope: String?
}

public struct EventsSinceResult: Codable, Sendable, Hashable {
    public var events: [JSONValue]
    public var latestSeq: Int
    public var replayEpoch: String
    public var snapshotRequired: Bool
    public var truncated: Bool?
    public var openRequests: [OpenRequest]?

    enum CodingKeys: String, CodingKey {
        case events
        case latestSeq = "latest_seq"
        case replayEpoch = "replay_epoch"
        case snapshotRequired = "snapshot_required"
        case truncated
        case openRequests = "open_requests"
    }
}

public struct PromptResponseResult: Codable, Sendable, Hashable {
    public var status: String
    public var promptID: String

    enum CodingKeys: String, CodingKey {
        case status
        case promptID = "prompt_id"
    }
}

public struct ProfileCanonicalSession: Codable, Sendable, Hashable {
    public var id: String
    public var resolvedID: String
    public var title: String?
    public var messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case resolvedID = "resolved_id"
        case title
        case messageCount = "message_count"
    }
}

public struct ProfileRow: Codable, Sendable, Hashable {
    public var name: String
    public var displayName: String?
    public var isDefault: Bool?
    public var canonicalSession: ProfileCanonicalSession?
    public var uiMeta: JSONValue?
    public var hasAvatar: Bool?
    public var onboardingPending: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case isDefault = "is_default"
        case canonicalSession = "canonical_session"
        case uiMeta = "ui_meta"
        case hasAvatar = "has_avatar"
        case onboardingPending = "onboarding_pending"
    }

    public var botMeta: JSONValue? { uiMeta?["hermes-bots"] }
}

public struct ProfilesListResult: Codable, Sendable, Hashable {
    public var profiles: [ProfileRow]
    public var botBirthNotice: Bool?

    enum CodingKeys: String, CodingKey {
        case profiles
        case botBirthNotice = "bot_birth_notice"
    }
}
