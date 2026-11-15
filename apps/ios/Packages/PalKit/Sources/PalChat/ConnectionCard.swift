import Foundation
import PalProtocol

public enum ConnectionDecision: Sendable, Hashable {
    case allow
    case deny
    case tryAgain

    var answerStatus: String {
        switch self {
        case .allow, .tryAgain: "approved"
        case .deny: "skipped"
        }
    }
}

public struct ConnectionCard: Sendable, Hashable {
    public var operation: ConnectionOperation
    public var lapsed: Bool

    public init(operation: ConnectionOperation, lapsed: Bool = false) {
        self.operation = operation
        self.lapsed = lapsed
    }

    static let toolName = "manage_connections"

    static func itemID(_ opID: String) -> String { "connection:\(opID)" }

    public func isOpen(now: Date) -> Bool {
        !operation.settled && !lapsed && now < operation.deadlineAt
    }

    public func decisions(for target: ConnectionTarget, now: Date) -> [ConnectionDecision] {
        guard isOpen(now: now) else { return [] }
        let isMCP = target.kind == "mcp"
        switch target.state {
        case .pending: return isMCP ? [.allow, .deny] : [.deny]
        case .failed, .expired: return isMCP ? [.tryAgain] : []
        default: return []
        }
    }

    public func isActionable(now: Date) -> Bool {
        operation.targets.contains { !decisions(for: $0, now: now).isEmpty }
    }
}
