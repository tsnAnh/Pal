import Foundation
import PalProtocol
import PalTransport

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
        if let rejection = photoRejections[rpc.code] { return .rejected(code: rejection) }
        if rpc.code == photoStorageFailureCode { return .unavailable }
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
        case .unavailable: "Pal could not save that right now. Try again in a moment."
        case .notFound: "That item no longer exists."
        case .offline: "Could not reach Pal. Check your connection and try again."
        case .rejected(let code): Self.rejectionMessages[code] ?? "Pal could not complete that."
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
        "photo_unreadable": "That picture couldn't be used. Try a JPEG or PNG under 10 MB.",
        "photo_too_large": "That picture couldn't be used. Try a JPEG or PNG under 10 MB.",
        "photo_format": "That picture couldn't be used. Try a JPEG or PNG under 10 MB.",
    ]

    private static let photoStorageFailureCode = 5067

    private static let photoRejections: [Int: String] = [
        4068: "photo_unreadable", 4069: "photo_too_large", 4070: "photo_format",
    ]
}

public struct OwnerPhotoDownload: Sendable, Equatable {
    public let version: String
    public let data: Data

    public init(version: String, data: Data) {
        self.version = version
        self.data = data
    }
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

    @discardableResult
    public func addVaultAPIKey(_ draft: VaultAPIKeyDraft) async throws -> String {
        guard draft.isComplete else { throw SettingsFailure.rejected(code: "incomplete") }
        return try await perform(SettingsWire.VaultAdded.self, "vault.add", [
            "kind": "api_key",
            "label": .string(draft.trimmedLabel),
            "secret": .object(["api_key": .string(draft.apiKey)]),
        ]).id
    }

    public func updateVaultItem(_ draft: VaultEditDraft) async throws {
        guard draft.isComplete else { throw SettingsFailure.rejected(code: "incomplete") }
        var params: [String: JSONValue] = ["id": .string(draft.id), "label": .string(draft.trimmedLabel)]
        var secret: [String: JSONValue] = [:]
        switch draft.kind {
        case .login:
            if let origin = draft.normalizedOrigin { params["origin"] = .string(origin) }
            secret["identifier"] = .string(draft.trimmedIdentifier)
            secret["identifier_type"] = .string(draft.identifierType)
            if !draft.secret.isEmpty { secret["password"] = .string(draft.secret) }
        case .apiKey:
            if !draft.secret.isEmpty { secret["api_key"] = .string(draft.secret) }
        case .payment, .address, .other:
            break
        }
        if !secret.isEmpty { params["secret"] = .object(secret) }
        _ = try await perform(SettingsWire.VaultUpdated.self, "vault.update", params)
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

    public func setOwnerName(_ name: String) async throws -> SettingsWire.AboutYou {
        try await perform(SettingsWire.AboutYou.self, "bot_mode.about_you.set", ["name": .string(name)])
    }

    public func setOwnerPhoto(_ jpeg: Data?) async throws -> SettingsWire.AboutYou {
        guard (jpeg?.count ?? 0) <= OwnerPhotoImage.maximumUploadBytes else { throw SettingsFailure.rejected(code: "photo_too_large") }
        let data: JSONValue = jpeg.map { .string($0.base64EncodedString()) } ?? .null
        return try await perform(SettingsWire.AboutYou.self, "bot_mode.about_you.set_photo", ["data": data])
    }

    public func ownerPhoto() async throws -> OwnerPhotoDownload? {
        let payload = try await perform(SettingsWire.OwnerPhotoPayload.self, "bot_mode.about_you.photo")
        guard !payload.photoVersion.isEmpty else { return nil }
        guard let data = Data(base64Encoded: payload.data) else { throw SettingsFailure.unexpected }
        return OwnerPhotoDownload(version: payload.photoVersion, data: data)
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

public enum NotificationFlag {
    public static func isOn(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag)?: flag
        case .string(let word)?: !["off", "false", "no", "0"].contains(word.lowercased())
        default: true
        }
    }
}
