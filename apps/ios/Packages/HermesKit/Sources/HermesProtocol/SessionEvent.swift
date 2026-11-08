import Foundation

public struct ToolStart: Codable, Sendable, Hashable {
    public var toolID: String
    public var name: String
    public var context: String?
    public var preview: String?

    enum CodingKeys: String, CodingKey {
        case toolID = "tool_id"
        case name
        case context
        case preview
    }
}

public struct ToolComplete: Codable, Sendable, Hashable {
    public var toolID: String
    public var name: String
    public var summary: String?
    public var result: String?
    public var resultText: String?
    public var durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case toolID = "tool_id"
        case name
        case summary
        case result
        case resultText = "result_text"
        case durationSeconds = "duration_s"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolID = try container.decode(String.self, forKey: .toolID)
        name = try container.decode(String.self, forKey: .name)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        result = try? container.decodeIfPresent(String.self, forKey: .result)
        resultText = try? container.decodeIfPresent(String.self, forKey: .resultText)
        durationSeconds = try? container.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }
}

public struct MessageStart: Codable, Sendable, Hashable {
    public var turnID: String?
    public var displayKind: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case displayKind = "display_kind"
    }
}

public struct MessageDelta: Codable, Sendable, Hashable {
    public var text: String?
    public var turnID: String?
    public var segment: Int?
    public var offset: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case turnID = "turn_id"
        case segment
        case offset
    }
}

public struct MessageInterim: Codable, Sendable, Hashable {
    public var text: String
    public var turnID: String?
    public var segment: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case turnID = "turn_id"
        case segment
    }
}

public struct MessageComplete: Codable, Sendable, Hashable {
    public var text: String
    public var status: String?
    public var error: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey {
        case text
        case status
        case error
    }
}

public struct SessionInfoUpdate: Codable, Sendable, Hashable {
    public var running: Bool?
    public var pending: [PendingAdmission]?
    public var title: String?
}

public struct ReplayGap: Codable, Sendable, Hashable {
    public var replayEpoch: String?
    public var latestSeq: Int?

    enum CodingKeys: String, CodingKey {
        case replayEpoch = "replay_epoch"
        case latestSeq = "latest_seq"
    }
}

public struct PromptSettled: Codable, Sendable, Hashable {
    public var promptID: String

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
    }
}

private struct TextPayload: Decodable {
    var text: String?
}

private struct ErrorPayload: Decodable {
    var message: String?
}

public enum SessionEvent: Sendable, Hashable {
    case messageStart(MessageStart)
    case messageDelta(MessageDelta)
    case messageInterim(MessageInterim)
    case messageComplete(MessageComplete)
    case reasoningDelta(String)
    case toolStart(ToolStart)
    case toolComplete(ToolComplete)
    case clarifyRequest(PendingPrompt)
    case clarifySettled(PromptSettled)
    case approvalRequest(PendingPrompt)
    case approvalSettled(PromptSettled)
    case sessionInfo(SessionInfoUpdate)
    case replayGap(ReplayGap)
    case error(String)
    case unknown(type: String, payload: JSONValue?)

    public init(type: String, payload: JSONValue?) {
        let value = payload ?? .object([:])
        let decoded: SessionEvent?
        switch type {
        case "message.start": decoded = (try? value.decoded(as: MessageStart.self)).map(SessionEvent.messageStart)
        case "message.delta": decoded = (try? value.decoded(as: MessageDelta.self)).map(SessionEvent.messageDelta)
        case "message.interim": decoded = (try? value.decoded(as: MessageInterim.self)).map(SessionEvent.messageInterim)
        case "message.complete": decoded = (try? value.decoded(as: MessageComplete.self)).map(SessionEvent.messageComplete)
        case "reasoning.delta":
            decoded = (try? value.decoded(as: TextPayload.self)).flatMap(\.text).map(SessionEvent.reasoningDelta)
        case "tool.start": decoded = (try? value.decoded(as: ToolStart.self)).map(SessionEvent.toolStart)
        case "tool.complete": decoded = (try? value.decoded(as: ToolComplete.self)).map(SessionEvent.toolComplete)
        case "clarify.request": decoded = (try? value.decoded(as: PendingPrompt.self)).map(SessionEvent.clarifyRequest)
        case "clarify.settled": decoded = (try? value.decoded(as: PromptSettled.self)).map(SessionEvent.clarifySettled)
        case "approval.request": decoded = (try? value.decoded(as: PendingPrompt.self)).map(SessionEvent.approvalRequest)
        case "approval.settled": decoded = (try? value.decoded(as: PromptSettled.self)).map(SessionEvent.approvalSettled)
        case "session.info": decoded = (try? value.decoded(as: SessionInfoUpdate.self)).map(SessionEvent.sessionInfo)
        case "session.replay_gap": decoded = (try? value.decoded(as: ReplayGap.self)).map(SessionEvent.replayGap)
        case "error": decoded = .error((try? value.decoded(as: ErrorPayload.self))?.message ?? "")
        default: decoded = nil
        }
        self = decoded ?? .unknown(type: type, payload: payload)
    }
}

public struct SessionEventFrame: Sendable, Hashable {
    public var event: SessionEvent
    public var sessionID: String?
    public var seq: Int?
    public var replayEpoch: String?
    public var executionGeneration: Int?
    public var admissionID: String?

    public init(
        event: SessionEvent,
        sessionID: String? = nil,
        seq: Int? = nil,
        replayEpoch: String? = nil,
        executionGeneration: Int? = nil,
        admissionID: String? = nil
    ) {
        self.event = event
        self.sessionID = sessionID
        self.seq = seq
        self.replayEpoch = replayEpoch
        self.executionGeneration = executionGeneration
        self.admissionID = admissionID
    }

    public init(_ gateway: GatewayEvent) {
        self.init(
            event: SessionEvent(type: gateway.type, payload: gateway.payload),
            sessionID: gateway.sessionID,
            seq: gateway.seq,
            replayEpoch: gateway.replayEpoch,
            executionGeneration: gateway.executionGeneration,
            admissionID: gateway.admissionID
        )
    }
}
