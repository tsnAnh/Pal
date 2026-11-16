import Foundation
import PalProtocol
import PalTransport

public struct KanbanGateway: Sendable {
    public typealias Call = @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue

    private let perform: Call

    public init(call: @escaping Call) {
        perform = call
    }

    func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await perform(method, .object(params))
    }
}

public enum KanbanFailure: Error, Sendable, Equatable {
    case unsupported
    case permissionDenied
    case gatewayMismatch
    case profileMismatch
    case invalidParams
    case invalidResponse
    case unavailable
    case unreachable

    static func classify(_ error: any Error) -> KanbanFailure {
        if let failure = error as? KanbanFailure { return failure }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unreachable }
        if rpc.code == -32601 { return .unsupported }
        switch rpc.reasonCode ?? rpc.message {
        case "permission_denied": return .permissionDenied
        case "gateway_mismatch": return .gatewayMismatch
        case "profile_mismatch": return .profileMismatch
        case "invalid_params": return .invalidParams
        default: return .unavailable
        }
    }
}

public struct KanbanService: Sendable {
    public static let methods: [String] = [
        "kanban.boards.list", "kanban.board.snapshot", "kanban.card.get", "kanban.evidence.list", "kanban.events.since",
    ]

    private let gateway: KanbanGateway

    public init(gateway: KanbanGateway) {
        self.gateway = gateway
    }

    public func boards(gatewayID: String?) async throws -> KanbanBoardsList {
        try await read("kanban.boards.list", scoped(gatewayID), as: KanbanBoardsList.init)
    }

    public func snapshot(board: String, gatewayID: String?, limit: Int, pageToken: String?) async throws -> KanbanSnapshotPage {
        var params = scoped(gatewayID, board: board)
        params["limit"] = .int(limit)
        if let pageToken { params["page_token"] = .string(pageToken) }
        return try await read("kanban.board.snapshot", params, as: KanbanSnapshotPage.init)
    }

    public func card(board: String, taskID: String, gatewayID: String?) async throws -> KanbanCardResult {
        var params = scoped(gatewayID, board: board)
        params["task_id"] = .string(taskID)
        return try await read("kanban.card.get", params, as: KanbanCardResult.init)
    }

    public func evidence(board: String, taskID: String, runID: Int?, gatewayID: String?) async throws -> KanbanEvidenceResult {
        var params = scoped(gatewayID, board: board)
        params["task_id"] = .string(taskID)
        if let runID { params["run_id"] = .int(runID) }
        return try await read("kanban.evidence.list", params, as: KanbanEvidenceResult.init)
    }

    public func events(board: String, cursor: String, limit: Int, gatewayID: String?) async throws -> KanbanEventsPage {
        var params = scoped(gatewayID, board: board)
        params["cursor"] = .string(cursor)
        params["limit"] = .int(limit)
        return try await read("kanban.events.since", params, as: KanbanEventsPage.init)
    }

    private func scoped(_ gatewayID: String?, board: String? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let gatewayID { params["gateway_id"] = .string(gatewayID) }
        if let board { params["board"] = .string(board) }
        return params
    }

    private func read<Value>(_ method: String, _ params: [String: JSONValue], as decode: (JSONValue) -> Value?) async throws -> Value {
        let result: JSONValue
        do {
            result = try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KanbanFailure.classify(error)
        }
        guard let value = decode(result) else { throw KanbanFailure.invalidResponse }
        return value
    }
}
