import Foundation
import HermesClient
import HermesProtocol
import HermesTransport

public enum ChatError: Error, Sendable, Equatable {
    case notConnected
    case unexpectedResponse(method: String)
    case titleNotApplied
    case attachmentRefused
}

public struct StagedImage: Decodable, Sendable, Hashable {
    public var attached: Bool
    public var path: String
    public var mime: String
    public var name: String
    public var text: String?

    public var promptAttachment: PromptAttachment { PromptAttachment(path: path, mime: mime) }
}

public struct StagedFile: Decodable, Sendable, Hashable {
    public var attached: Bool
    public var name: String
    public var path: String
    public var refText: String

    enum CodingKeys: String, CodingKey {
        case attached
        case name
        case path
        case refText = "ref_text"
    }
}

public struct PromptAttachment: Codable, Sendable, Hashable {
    public var path: String
    public var mime: String

    public init(path: String, mime: String) {
        self.path = path
        self.mime = mime
    }
}

public enum SteerStatus: String, Sendable, Equatable {
    case queued
    case rejected
}

public protocol ChatConnector: Sendable {
    func connect() async throws -> GatewayConnection
}

public struct HermesClientConnector: ChatConnector {
    public let client: HermesClient

    public init(client: HermesClient) {
        self.client = client
    }

    public func connect() async throws -> GatewayConnection {
        try await client.connect()
    }
}

public enum ReactionTarget: Sendable, Hashable {
    case row(Int)
    case newest(role: String)
}

public struct SessionAPI: Sendable {
    public let connection: GatewayConnection
    public let profile: String

    public init(connection: GatewayConnection, profile: String) {
        self.connection = connection
        self.profile = profile
    }

    public func list(title: String, includeHidden: Bool = true) async throws -> [SessionListRow] {
        let result = try await call("session.list", [
            "title": .string(title),
            "include_hidden": .bool(includeHidden),
        ])
        return try decode(SessionListResult.self, result, "session.list").sessions
    }

    public func create(title: String, requestID: String, hidden: Bool) async throws -> SessionSnapshot {
        let result = try await call("session.create", [
            "title": .string(title),
            "hidden": .bool(hidden),
            "request_id": .string(requestID),
            "source": .string(RuntimeDescription.createSource(advertised: connection.negotiatedRuntime)),
        ])
        return try decode(SessionSnapshot.self, result, "session.create")
    }

    public func resume(sessionID: String) async throws -> SessionSnapshot {
        let result = try await call("session.resume", ["session_id": .string(sessionID)])
        return try decode(SessionSnapshot.self, result, "session.resume")
    }

    public func eventsSince(sessionID: String, lastSequence: Int, replayEpoch: String) async throws -> EventsSinceResult {
        let result = try await call("session.events.since", [
            "session_id": .string(sessionID),
            "last_sequence": .int(lastSequence),
            "replay_epoch": .string(replayEpoch),
        ])
        return try decode(EventsSinceResult.self, result, "session.events.since")
    }

    public func submit(
        sessionID: String,
        text: String,
        submissionID: String,
        attachments: [PromptAttachment] = [],
        hidden: Bool = false,
        voiceTurn: Bool = false
    ) async throws -> AdmissionStatus {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
            "submission_id": .string(submissionID),
        ]
        if !attachments.isEmpty {
            params["attachments"] = .array(attachments.map { ["path": .string($0.path), "mime": .string($0.mime)] })
        }
        if hidden { params["display_kind"] = "hidden" }
        if voiceTurn { params["voice_turn"] = true }
        let result = try await call("prompt.submit", params)
        return try decode(AdmissionStatus.self, result, "prompt.submit")
    }

    /// The commands and skills the `/` picker offers; `session_id` scopes project-local skills to the chat.
    public func slashCommands(sessionID: String) async throws -> [SlashItem] {
        let result = try await call("commands.catalog", ["session_id": .string(sessionID)])
        return SlashCatalog.parse(result)
    }

    public func attachImage(sessionID: String, data: Data, filename: String) async throws -> StagedImage {
        let result = try await call("image.attach_bytes", [
            "session_id": .string(sessionID),
            "content_base64": .string(data.base64EncodedString()),
            "filename": .string(filename),
        ])
        let staged = try decode(StagedImage.self, result, "image.attach_bytes")
        guard staged.attached else { throw ChatError.attachmentRefused }
        return staged
    }

    public func attachFile(sessionID: String, data: Data, name: String, mime: String) async throws -> StagedFile {
        let result = try await call("file.attach", [
            "session_id": .string(sessionID),
            "data_url": .string("data:\(mime);base64,\(data.base64EncodedString())"),
            "name": .string(name),
        ])
        let staged = try decode(StagedFile.self, result, "file.attach")
        guard staged.attached else { throw ChatError.attachmentRefused }
        return staged
    }

    public func respondToClarify(
        sessionID: String,
        executionGeneration: Int,
        promptID: String,
        answer: String
    ) async throws -> PromptResponseResult {
        let result = try await call("clarify.respond", [
            "session_id": .string(sessionID),
            "execution_generation": .int(executionGeneration),
            "prompt_id": .string(promptID),
            "answer": .string(answer),
        ])
        return try decode(PromptResponseResult.self, result, "clarify.respond")
    }

    public func respondToApproval(
        sessionID: String,
        executionGeneration: Int,
        promptID: String,
        choice: String
    ) async throws -> PromptResponseResult {
        let result = try await call("approval.respond", [
            "session_id": .string(sessionID),
            "execution_generation": .int(executionGeneration),
            "prompt_id": .string(promptID),
            "choice": .string(choice),
        ])
        return try decode(PromptResponseResult.self, result, "approval.respond")
    }

    public func react(sessionID: String, target: ReactionTarget, emoji: String?) async throws -> String? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), "emoji": emoji.map(JSONValue.string) ?? .null]
        switch target {
        case .row(let id): params["row_id"] = .int(id)
        case .newest(let role): params["newest_role"] = .string(role)
        }
        let result = try await call("message.react", params)
        let reactions = result["reactions"]?.arrayValue ?? []
        return reactions.first { $0["author"]?.stringValue == "user" }?["emoji"]?.stringValue
    }

    public func interrupt(sessionID: String, executionGeneration: Int) async throws {
        _ = try await call("session.interrupt", [
            "session_id": .string(sessionID),
            "execution_generation": .int(executionGeneration),
        ])
    }

    public func steer(sessionID: String, text: String, executionGeneration: Int) async throws -> SteerStatus {
        let result = try await call("session.steer", [
            "session_id": .string(sessionID),
            "text": .string(text),
            "execution_generation": .int(executionGeneration),
        ])
        return SteerStatus(rawValue: result["status"]?.stringValue ?? "") ?? .rejected
    }

    public func profiles() async throws -> ProfilesListResult {
        let result = try await connection.call("profiles.list", params: ["include_sessions": true])
        return try decode(ProfilesListResult.self, result, "profiles.list")
    }

    func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        var scoped = params
        scoped["profile"] = .string(profile)
        return try await connection.call(method, params: .object(scoped))
    }

    func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue, _ method: String) throws -> T {
        do {
            return try value.decoded(as: type)
        } catch {
            throw ChatError.unexpectedResponse(method: method)
        }
    }
}

public struct RefusalReason: Sendable, Equatable {
    public static let permanentReasons: Set<String> = [
        "permission_denied", "invalid_params", "admission_conflict", "profile_mismatch",
    ]

    public var reason: String
    public var isPermanent: Bool

    public init?(_ error: any Error) {
        switch error {
        case GatewayTransportError.rpc(let rpc):
            reason = rpc.data?["reason"]?.stringValue ?? rpc.message
            isPermanent = rpc.data?["reason"]?.stringValue.map(Self.permanentReasons.contains) ?? false
        default:
            return nil
        }
    }
}
