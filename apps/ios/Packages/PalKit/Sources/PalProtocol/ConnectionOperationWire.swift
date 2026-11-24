import Foundation

public enum ConnectionTargetState: Sendable, Hashable {
    case pending
    case initiated
    case connected
    case skipped
    case declined
    case failed
    case expired
    case notConnected
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "initiated": self = .initiated
        case "connected": self = .connected
        case "skipped": self = .skipped
        case "declined": self = .declined
        case "failed": self = .failed
        case "expired": self = .expired
        case "not_connected": self = .notConnected
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .initiated: "initiated"
        case .connected: "connected"
        case .skipped: "skipped"
        case .declined: "declined"
        case .failed: "failed"
        case .expired: "expired"
        case .notConnected: "not_connected"
        case .unknown(let raw): raw
        }
    }
}

public enum ConnectionSettleReason: Sendable, Hashable {
    case allResolved
    case continued
    case deadline
    case interrupt
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "all_resolved": self = .allResolved
        case "continue": self = .continued
        case "deadline": self = .deadline
        case "interrupt": self = .interrupt
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .allResolved: "all_resolved"
        case .continued: "continue"
        case .deadline: "deadline"
        case .interrupt: "interrupt"
        case .unknown(let raw): raw
        }
    }
}

public struct ConnectionTarget: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: String
    public var action: String
    public var state: ConnectionTargetState
    public var detail: String?
    public var discoveryError: String?
    public var tools: [String]

    public var id: String { name }

    public init(
        name: String,
        kind: String,
        action: String,
        state: ConnectionTargetState,
        detail: String? = nil,
        discoveryError: String? = nil,
        tools: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.action = action
        self.state = state
        self.detail = detail
        self.discoveryError = discoveryError
        self.tools = tools
    }
}

extension ConnectionTarget: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, kind, action, state, detail, tools
        case discoveryError = "discovery_error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "empty target name")
        }
        self.init(
            name: name,
            kind: (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? "",
            action: (try? container.decodeIfPresent(String.self, forKey: .action)) ?? "",
            state: ConnectionTargetState(rawValue: (try? container.decodeIfPresent(String.self, forKey: .state)) ?? ""),
            detail: try? container.decodeIfPresent(String.self, forKey: .detail),
            discoveryError: try? container.decodeIfPresent(String.self, forKey: .discoveryError),
            tools: (try? container.decodeIfPresent([String].self, forKey: .tools)) ?? []
        )
    }
}

public struct ConnectionOperation: Sendable, Hashable {
    public var opID: String
    public var seq: Int
    public var deadlineAt: Date
    public var targets: [ConnectionTarget]
    public var toolCallID: String?
    public var settled: Bool
    public var settledBy: ConnectionSettleReason?
    public var ownerSessionID: String?

    public init(
        opID: String,
        seq: Int,
        deadlineAt: Date,
        targets: [ConnectionTarget],
        toolCallID: String? = nil,
        settled: Bool = false,
        settledBy: ConnectionSettleReason? = nil,
        ownerSessionID: String? = nil
    ) {
        self.opID = opID
        self.seq = seq
        self.deadlineAt = deadlineAt
        self.targets = targets
        self.toolCallID = toolCallID
        self.settled = settled
        self.settledBy = settledBy
        self.ownerSessionID = ownerSessionID
    }

    public func closed() -> ConnectionOperation {
        var copy = self
        copy.settled = true
        return copy
    }

    public init?(value: JSONValue) {
        guard let operation = try? value.decoded(as: ConnectionOperation.self) else { return nil }
        self = operation
    }

    public init?(toolResult text: String?) {
        guard let text, let data = text.data(using: .utf8),
              let operation = try? JSONDecoder().decode(ConnectionOperation.self, from: data)
        else { return nil }
        self = operation
    }
}

extension ConnectionOperation: Decodable {
    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case seq
        case deadlineAt = "deadline_at"
        case targets
        case toolCallID = "tool_call_id"
        case settled
        case settledAt = "settled_at"
        case settledBy = "settled_by"
        case owner
    }

    private struct Owner: Decodable {
        var sessionID: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
    }

    private struct LossyTarget: Decodable {
        var target: ConnectionTarget?

        init(from decoder: any Decoder) throws {
            target = try? ConnectionTarget(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let opID = try container.decode(String.self, forKey: .opID)
        guard !opID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .opID, in: container, debugDescription: "empty op_id")
        }
        let deadline = try container.decode(Double.self, forKey: .deadlineAt)
        let settledAt = try? container.decodeIfPresent(Double.self, forKey: .settledAt)
        let flag = (try? container.decodeIfPresent(Bool.self, forKey: .settled)) ?? false
        let lossy = try container.decodeIfPresent([LossyTarget].self, forKey: .targets) ?? []
        self.init(
            opID: opID,
            seq: try container.decode(Int.self, forKey: .seq),
            deadlineAt: Date(timeIntervalSince1970: deadline),
            targets: lossy.compactMap(\.target),
            toolCallID: try? container.decodeIfPresent(String.self, forKey: .toolCallID),
            settled: flag || settledAt != nil,
            settledBy: (try? container.decodeIfPresent(String.self, forKey: .settledBy)).map(ConnectionSettleReason.init(rawValue:)),
            ownerSessionID: (try? container.decodeIfPresent(Owner.self, forKey: .owner))?.sessionID
        )
    }
}
