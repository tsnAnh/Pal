import Foundation
import PalProtocol
import PalTransport

public enum TeachFailure: Error, Equatable, Sendable {
    case unavailable
    case draftPending
    case notInControl
    case recordingInProgress
    case draftChanged
    case recordingDeleted
    case notReady
    case invalidSkill
    case extraFiles
    case notAllowed
    case offline
    case failed

    public static func classify(_ error: any Error) -> TeachFailure {
        if let failure = error as? TeachFailure { return failure }
        if error is BotsError { return BotsError.classify(error) == .permissionDenied ? .notAllowed : .failed }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .offline }
        if rpc.code == -32601 { return .unavailable }
        switch rpc.data?["code"]?.stringValue ?? rpc.reasonCode ?? rpc.message {
        case "draft_pending": return .draftPending
        case "not_in_control": return .notInControl
        case "recording_in_progress": return .recordingInProgress
        case "draft_changed": return .draftChanged
        case "recording_deleted": return .recordingDeleted
        case "draft_not_ready": return .notReady
        case "invalid_skill", "skill_write_failed": return .invalidSkill
        case "extra_files": return .extraFiles
        case "unsupported", "sandbox", "no_browser", "unavailable": return .unavailable
        case "permission_denied", "profile_mismatch": return .notAllowed
        default: return .failed
        }
    }
}

public enum TeachPhase: Equatable, Sendable {
    case hidden
    case idle
    case recording
    case ended
    case drafting
    case ready
}

public struct TeachPending: Equatable, Sendable {
    public let teachID: String
    public let skillName: String
    public let eventCount: Int
    public let truncated: Bool
    public let isReady: Bool

    init(_ wire: BotTeachPendingWire) {
        teachID = wire.teachID
        skillName = wire.skillName
        eventCount = wire.eventCount
        truncated = wire.truncated
        isReady = wire.state == "ready"
    }
}

public struct TeachSnapshot: Equatable, Sendable {
    public static let recordingPoll: Duration = .seconds(2)
    public static let draftingPoll: Duration = .seconds(3)
    public static let endedPoll: Duration = .seconds(5)

    public let available: Bool
    public let isRecording: Bool
    public let waitingForBrowser: Bool
    public let ended: String?
    public let pending: TeachPending?
    public let truncated: Bool
    private let deadlineAt: Double?
    private let skew: Double

    public init(_ wire: BotTeachStatusWire, receivedAt: Double) {
        available = wire.available
        isRecording = wire.recording
        waitingForBrowser = wire.recording && wire.capture == "waiting"
        ended = wire.ended
        pending = wire.pending.map(TeachPending.init)
        truncated = wire.truncated
        deadlineAt = wire.deadlineAt
        skew = wire.now - receivedAt
    }

    public func phase(live: Bool) -> TeachPhase {
        guard live else { return .hidden }
        if isRecording { return .recording }
        if ended != nil { return .ended }
        if let pending { return pending.isReady ? .ready : .drafting }
        return available ? .idle : .hidden
    }

    public func secondsLeft(at nowSeconds: Double) -> Int {
        guard let deadlineAt else { return 0 }
        return max(0, Int((deadlineAt - (nowSeconds + skew)).rounded(.up)))
    }

    public var pollDelay: Duration? {
        if isRecording { return Self.recordingPoll }
        if ended != nil { return Self.endedPoll }
        if let pending, !pending.isReady { return Self.draftingPoll }
        return nil
    }

    public static func clock(_ seconds: Int) -> String {
        let whole = max(0, seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

public struct TeachStopOutcome: Equatable, Sendable {
    public let prompt: String?
    public let reason: String?
    public var isEmpty: Bool { prompt == nil }
}

public struct TeachDraft: Equatable, Sendable {
    public let teachID: String
    public let skillName: String
    public let eventCount: Int
    public let truncated: Bool
    public let content: String?
    public let contentHash: String?
    public let extraFiles: [String]
    public let isReady: Bool

    init(_ wire: BotTeachDraftWire) {
        teachID = wire.teachID
        skillName = wire.skillName
        eventCount = wire.eventCount
        truncated = wire.truncated
        content = wire.content
        contentHash = wire.contentHash
        extraFiles = wire.extraFiles
        isReady = wire.state == "ready" && wire.content != nil
    }

    public var canApprove: Bool { isReady && contentHash != nil && extraFiles.isEmpty }
}

public struct TeachService: Sendable {
    private let gateway: BotsGateway
    private let clock: @Sendable () -> Double

    public init(gateway: BotsGateway, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.gateway = gateway
        self.clock = clock
    }

    public func status(for name: String) async throws -> TeachSnapshot {
        try await snapshot(try await call("bot.teach.status", name))
    }

    public func start(for name: String, viewerID: String) async throws -> TeachSnapshot {
        try await snapshot(try await call("bot.teach.start", name, ["viewer_id": .string(viewerID)]))
    }

    public func stop(for name: String, discard: Bool) async throws -> TeachStopOutcome {
        let wire = try await decode(BotTeachStopWire.self, try await call("bot.teach.stop", name, ["discard": .bool(discard)]))
        let prompt = wire.empty ? nil : wire.prompt.flatMap { $0.isEmpty ? nil : $0 }
        return TeachStopOutcome(prompt: prompt, reason: wire.reason)
    }

    public func prompt(for name: String, teachID: String) async throws -> String {
        try await decode(BotTeachPromptWire.self, try await call("bot.teach.prompt", name, ["teach_id": .string(teachID)])).prompt
    }

    public func draft(for name: String, teachID: String) async throws -> TeachDraft {
        TeachDraft(try await decode(BotTeachDraftWire.self, try await call("bot.teach.draft", name, ["teach_id": .string(teachID)])))
    }

    public func approve(for name: String, draft: TeachDraft) async throws -> String {
        guard draft.canApprove, let hash = draft.contentHash else { throw TeachFailure.notReady }
        let wire = try await decode(BotTeachApproveWire.self, try await call("bot.teach.approve", name, [
            "teach_id": .string(draft.teachID),
            "content_hash": .string(hash),
        ]))
        guard wire.enabled else { throw TeachFailure.failed }
        return wire.skillName
    }

    public func discard(for name: String, teachID: String) async throws {
        let wire = try await decode(BotTeachDiscardWire.self, try await call("bot.teach.discard", name, ["teach_id": .string(teachID)]))
        guard wire.discarded else { throw TeachFailure.failed }
    }

    private func snapshot(_ value: JSONValue) throws -> TeachSnapshot {
        TeachSnapshot(try decode(BotTeachStatusWire.self, value), receivedAt: clock())
    }

    private func call(_ method: String, _ name: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.scoped(method, profile: name, params)
        } catch {
            throw error is CancellationError ? error : TeachFailure.classify(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        do {
            return try gateway.decoded(type, value)
        } catch {
            throw TeachFailure.failed
        }
    }
}
