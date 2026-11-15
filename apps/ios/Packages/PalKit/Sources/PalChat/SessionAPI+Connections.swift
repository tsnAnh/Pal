import Foundation
import PalProtocol

public struct ConnectionAnswer: Sendable, Hashable {
    public var name: String
    public var decision: ConnectionDecision

    public init(name: String, decision: ConnectionDecision) {
        self.name = name
        self.decision = decision
    }
}

struct ConnectionRespondResult: Decodable {
    var settled: Bool
}

extension SessionAPI {
    private func owner(_ sessionID: String) -> JSONValue {
        ["type": "session", "session_id": .string(sessionID)]
    }

    @discardableResult
    public func respondToConnection(sessionID: String, opID: String, targets: [ConnectionAnswer]) async throws -> Bool {
        let result = try await call("connection.respond", [
            "owner": owner(sessionID),
            "op_id": .string(opID),
            "result": ["targets": .array(targets.map { ["name": .string($0.name), "status": .string($0.decision.answerStatus)] })],
        ])
        return try decode(ConnectionRespondResult.self, result, "connection.respond").settled
    }

    public func connectionStatus(sessionID: String, opID: String) async throws -> ConnectionOperation {
        let result = try await call("connectors.operation.status", [
            "owner": owner(sessionID),
            "op_id": .string(opID),
        ])
        return try decode(ConnectionOperation.self, result, "connectors.operation.status")
    }
}
