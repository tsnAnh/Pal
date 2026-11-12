import Foundation
import Observation
import PalProtocol

@MainActor
@Observable
public final class ActionAutoApprove {
    public static let server = UpworkConnector.service
    public static let getMethod = "mcp.actions.auto_approve.get"
    public static let setMethod = "mcp.actions.auto_approve.set"

    public typealias Call = @Sendable (String, JSONValue?) async throws -> JSONValue

    public struct Entry: Sendable, Equatable {
        public var enabled: Bool
        public var eligible: Bool

        public init(enabled: Bool, eligible: Bool) {
            self.enabled = enabled
            self.eligible = eligible
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    public private(set) var pending: Set<String> = []
    public private(set) var failed: Set<String> = []

    @ObservationIgnored private let call: Call

    public init(call: @escaping Call) {
        self.call = call
    }

    public func entry(_ sessionID: String?) -> Entry? {
        sessionID.flatMap { entries[$0] }
    }

    public func showsSwitch(sessionID: String?, upworkConnected: Bool) -> Bool {
        upworkConnected && entry(sessionID)?.eligible == true
    }

    public func showsBanner(sessionID: String?) -> Bool {
        entry(sessionID)?.enabled == true
    }

    public func isPending(_ sessionID: String?) -> Bool {
        sessionID.map(pending.contains) ?? false
    }

    public func didFail(_ sessionID: String?) -> Bool {
        sessionID.map(failed.contains) ?? false
    }

    public func load(sessionID: String?) async {
        guard let sessionID, !sessionID.isEmpty else { return }
        do {
            let result = try await call(Self.getMethod, .object(Self.params(sessionID: sessionID)))
            entries[sessionID] = Entry(enabled: result["enabled"]?.boolValue ?? false, eligible: result["eligible"]?.boolValue ?? false)
        } catch is CancellationError {
            return
        } catch {
            entries[sessionID] = nil
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, sessionID: String?) async -> Bool {
        guard let sessionID, !sessionID.isEmpty, pending.insert(sessionID).inserted else { return false }
        defer { pending.remove(sessionID) }
        failed.remove(sessionID)
        var params = Self.params(sessionID: sessionID)
        params["enabled"] = .bool(enabled)
        do {
            let result = try await call(Self.setMethod, .object(params))
            guard let confirmed = result["enabled"]?.boolValue else {
                failed.insert(sessionID)
                return false
            }
            let eligible = entries[sessionID]?.eligible ?? true
            entries[sessionID] = Entry(enabled: confirmed, eligible: eligible)
            return confirmed == enabled
        } catch {
            failed.insert(sessionID)
            return false
        }
    }

    public func forget() {
        entries = [:]
        failed = []
    }

    private static func params(sessionID: String) -> [String: JSONValue] {
        ["session_id": .string(sessionID), "server": .string(server)]
    }
}
