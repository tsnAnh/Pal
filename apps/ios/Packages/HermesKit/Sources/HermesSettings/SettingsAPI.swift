import Foundation
import HermesProtocol
import HermesTransport

public enum SettingsFailure: Error, Sendable, Equatable {
    case notAllowed
    case unavailable
    case notFound
    case offline
    case rejected(code: String)
    case unexpected

    public init(_ error: any Error) {
        switch error {
        case let failure as SettingsFailure:
            self = failure
        case GatewayTransportError.rpc(let rpc):
            self = Self.classify(rpc)
        case GatewayTransportError.timedOut, GatewayTransportError.closed, GatewayTransportError.handshakeRejected:
            self = .offline
        case is URLError:
            self = .offline
        case is DecodingError:
            self = .unexpected
        default:
            self = .unexpected
        }
    }

    private static func classify(_ rpc: RPCError) -> SettingsFailure {
        let code = rpc.data?["code"]?.stringValue ?? rpc.reasonCode ?? ""
        switch code {
        case "permission_denied", "profile_mismatch": return .notAllowed
        case "storage_unavailable", "runtime_draining", "config_unreadable", "config_locked": return .unavailable
        case "not_found": return .notFound
        case "": return .unexpected
        default: return .rejected(code: code)
        }
    }

    public var message: String {
        switch self {
        case .notAllowed: "This account is not allowed to change that."
        case .unavailable: "Hermes could not save that right now. Try again in a moment."
        case .notFound: "That item no longer exists."
        case .offline: "Could not reach Hermes. Check your connection and try again."
        case .rejected(let code): Self.rejectionMessages[code] ?? "Hermes could not complete that."
        case .unexpected: "Something went wrong. Try again."
        }
    }

    private static let rejectionMessages: [String: String] = [
        "duplicate_rule": "That rule already exists.",
        "limit_reached": "You have reached the limit of rules for this list.",
        "text_too_long": "That rule is too long.",
        "empty_text": "Write a rule first.",
        "invalid_text": "That rule can't be saved.",
        "viewer_mismatch": "Someone is using the computer right now.",
    ]
}

public struct SettingsAPI: Sendable {
    public typealias Call = @Sendable (String, JSONValue?) async throws -> JSONValue

    private let call: Call
    public let profile: String?

    public init(profile: String? = nil, call: @escaping Call) {
        self.profile = profile
        self.call = call
    }

    public func scoped(to profile: String?) -> SettingsAPI {
        SettingsAPI(profile: profile, call: call)
    }

    private func perform<T: Decodable & Sendable>(
        _ type: T.Type, _ method: String, _ params: [String: JSONValue] = [:], scoped: Bool = true
    ) async throws -> T {
        var params = params
        if scoped, let profile { params["profile"] = .string(profile) }
        do {
            let result = try await call(method, .object(params))
            return try result.decoded(as: type, using: SettingsWire.decoder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SettingsFailure(error)
        }
    }

    public func subscriptions(refresh: Bool) async throws -> [SettingsWire.Subscription] {
        try await perform(SettingsWire.SubscriptionsResult.self, "account.subscriptions", ["refresh": .bool(refresh)]).subscriptions
    }

    public func permissions() async throws -> SettingsWire.PermissionsState {
        try await perform(SettingsWire.PermissionsState.self, "permissions.get")
    }

    public func setAutoReview(_ enabled: Bool) async throws -> SettingsWire.PermissionsState {
        try await perform(SettingsWire.PermissionsState.self, "permissions.set_auto_review", ["enabled": .bool(enabled)])
    }

    public func addRule(_ list: PermissionList, text: String) async throws -> SettingsWire.PermissionRule {
        try await perform(SettingsWire.PermissionRule.self, "permissions.rules.add", [
            "list": .string(list.rawValue), "text": .string(text),
        ])
    }

    public func removeRule(id: String) async throws {
        _ = try await perform(SettingsWire.RuleRemoval.self, "permissions.rules.remove", ["id": .string(id)])
    }

    public func vaultItems() async throws -> [SettingsWire.VaultItem] {
        try await perform(SettingsWire.VaultList.self, "vault.list").items
    }

    public func addVaultLogin(_ login: VaultLoginDraft) async throws {
        guard let origin = login.normalizedOrigin, login.isComplete else { throw SettingsFailure.rejected(code: "incomplete") }
        _ = try await perform(SettingsWire.VaultAdded.self, "vault.add", [
            "kind": "login",
            "label": .string(login.trimmedLabel),
            "origin": .string(origin),
            "secret": .object([
                "identifier_type": .string(login.identifierType),
                "identifier": .string(login.trimmedIdentifier),
                "password": .string(login.password),
            ]),
        ])
    }

    public func removeVaultItem(id: String) async throws {
        _ = try await perform(SettingsWire.VaultRemoval.self, "vault.remove", ["id": .string(id)])
    }

    public func displayStatus() async throws -> SettingsWire.DisplayStatus {
        try await perform(SettingsWire.DisplayStatus.self, "display.status")
    }

    public func resetDisplay() async throws -> SettingsWire.DisplayReset {
        try await perform(SettingsWire.DisplayReset.self, "display.reset")
    }

    public func devices() async throws -> [SettingsWire.Device] {
        try await perform(SettingsWire.DevicesList.self, "devices.list", scoped: false).devices
    }

    public func forgetDevice(id: String) async throws {
        _ = try await perform(SettingsWire.DeviceForgotten.self, "devices.forget", ["device_id": .string(id)], scoped: false)
    }

    public func aboutYou() async throws -> SettingsWire.AboutYou {
        try await perform(SettingsWire.AboutYou.self, "bot_mode.about_you.get")
    }

    public func setTimeZone(automatic: Bool, identifier: String?) async throws -> SettingsWire.AboutYou {
        var params: [String: JSONValue] = ["timezone_auto": .bool(automatic)]
        if let identifier { params["timezone"] = .string(identifier) }
        return try await perform(SettingsWire.AboutYou.self, "bot_mode.about_you.set", params)
    }

    public func sharedMetrics() async throws -> SettingsWire.SharedMetrics {
        try await perform(SettingsWire.SharedMetrics.self, "shared_metrics.status")
    }

    public func setSharedMetrics(enabled: Bool, send: Bool) async throws -> SettingsWire.SharedMetrics {
        try await perform(SettingsWire.SharedMetrics.self, "shared_metrics.set", [
            "enabled": .bool(enabled), "send": .bool(enabled && send),
        ])
    }

    public func importMemory(_ text: String) async throws -> SettingsWire.MemoryImport {
        try await perform(SettingsWire.MemoryImport.self, "memory.import", ["text": .string(text)])
    }

    public func notificationsEnabled(bot: String) async throws -> Bool {
        let reply = try await perform(SettingsWire.ConfigValue.self, "config.get", [
            "key": "bot_mode.notifications", "profile": .string(bot),
        ], scoped: false)
        return NotificationFlag.isOn(reply.value)
    }

    public func setNotifications(_ enabled: Bool, bot: String) async throws {
        _ = try await perform(SettingsWire.ConfigValue.self, "config.set", [
            "key": "bot_mode.notifications", "value": .string(enabled ? "on" : "off"), "profile": .string(bot),
        ], scoped: false)
    }
}

public enum PermissionList: String, Sendable, CaseIterable {
    case ask
    case allow
}

public enum NotificationFlag {
    public static func isOn(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?: flag
        case .string(let word)?: !["off", "false", "no", "0"].contains(word.lowercased())
        default: true
        }
    }
}
