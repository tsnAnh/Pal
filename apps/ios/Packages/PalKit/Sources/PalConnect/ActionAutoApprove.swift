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

    struct Key: Hashable, Sendable {
        var sessionID: String
        var account: String?
    }

    private(set) var entries: [Key: Entry] = [:]
    private(set) var pending: Set<Key> = []
    private(set) var failed: Set<Key> = []

    @ObservationIgnored private let call: Call

    public init(call: @escaping Call) {
        self.call = call
    }

    public func entry(_ sessionID: String?, account: String? = nil) -> Entry? {
        key(sessionID, account).flatMap { entries[$0] }
    }

    public func showsSwitch(sessionID: String?, upworkConnected: Bool, account: String? = nil) -> Bool {
        upworkConnected && entry(sessionID, account: account)?.eligible == true
    }

    public func showsBanner(sessionID: String?, account: String? = nil) -> Bool {
        entry(sessionID, account: account)?.enabled == true
    }

    public func isPending(_ sessionID: String?, account: String? = nil) -> Bool {
        key(sessionID, account).map(pending.contains) ?? false
    }

    public func didFail(_ sessionID: String?, account: String? = nil) -> Bool {
        key(sessionID, account).map(failed.contains) ?? false
    }

    public func load(sessionID: String?, account: String? = nil) async {
        guard let sessionID, !sessionID.isEmpty else { return }
        let key = Key(sessionID: sessionID, account: account)
        do {
            let result = try await call(Self.getMethod, .object(Self.params(key)))
            entries[key] = Entry(enabled: result["enabled"]?.boolValue ?? false, eligible: result["eligible"]?.boolValue ?? false)
        } catch is CancellationError {
            return
        } catch {
            entries[key] = nil
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, sessionID: String?, account: String? = nil) async -> Bool {
        guard let sessionID, !sessionID.isEmpty else { return false }
        let key = Key(sessionID: sessionID, account: account)
        guard pending.insert(key).inserted else { return false }
        defer { pending.remove(key) }
        failed.remove(key)
        var params = Self.params(key)
        params["enabled"] = .bool(enabled)
        do {
            let result = try await call(Self.setMethod, .object(params))
            guard let confirmed = result["enabled"]?.boolValue else {
                failed.insert(key)
                return false
            }
            let eligible = entries[key]?.eligible ?? true
            entries[key] = Entry(enabled: confirmed, eligible: eligible)
            return confirmed == enabled
        } catch {
            failed.insert(key)
            return false
        }
    }

    public func forget() {
        entries = [:]
        failed = []
    }

    private func key(_ sessionID: String?, _ account: String?) -> Key? {
        sessionID.map { Key(sessionID: $0, account: account) }
    }

    private static func params(_ key: Key) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["session_id": .string(key.sessionID), "server": .string(server)]
        if let account = key.account { params["account"] = .string(account) }
        return params
    }
}
