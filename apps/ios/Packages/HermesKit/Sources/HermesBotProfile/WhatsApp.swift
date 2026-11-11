import Foundation
import HermesProtocol
import HermesTransport

public enum WhatsAppMode: String, Sendable, Equatable, CaseIterable {
    case bot
    case selfChat = "self-chat"

    init?(wire: String?) {
        guard let wire else { return nil }
        self.init(rawValue: wire)
    }
}

public enum WhatsAppAllowedUsers {
    public static func normalized(_ text: String) -> String? {
        let entries = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard entries.allSatisfy(isPhoneNumber) else { return nil }
        return entries.joined(separator: ",")
    }

    private static func isPhoneNumber(_ entry: String) -> Bool {
        let digits = entry.hasPrefix("+") ? entry.dropFirst() : Substring(entry)
        return (5...15).contains(digits.count) && digits.allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

public struct WhatsAppQRPayload: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct WhatsAppReloadWire: Decodable, Sendable, Equatable {
    public var ok: Bool?
    public var hotServed: Bool?
    public var restartStarted: Bool?
    public var restartBusy: Bool?
    public var restartError: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case hotServed = "hot_served"
        case restartStarted = "restart_started"
        case restartBusy = "restart_busy"
        case restartError = "restart_error"
    }

    public init(ok: Bool? = nil, hotServed: Bool? = nil, restartStarted: Bool? = nil, restartBusy: Bool? = nil, restartError: String? = nil) {
        self.ok = ok
        self.hotServed = hotServed
        self.restartStarted = restartStarted
        self.restartBusy = restartBusy
        self.restartError = restartError
    }
}

public struct WhatsAppStatusWire: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var paired: Bool
    public var mode: String?
    public var allowedUsers: String?
    public var accountName: String?
    public var accountPhone: String?
    public var gatewayRunning: Bool?
    public var state: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var reload: WhatsAppReloadWire

    enum CodingKeys: String, CodingKey {
        case enabled, paired, mode, state
        case allowedUsers = "allowed_users"
        case accountName = "account_name"
        case accountPhone = "account_phone"
        case gatewayRunning = "gateway_running"
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        paired = try container.decode(Bool.self, forKey: .paired)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        allowedUsers = try container.decodeIfPresent(String.self, forKey: .allowedUsers)
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
        accountPhone = try container.decodeIfPresent(String.self, forKey: .accountPhone)
        gatewayRunning = try container.decodeIfPresent(Bool.self, forKey: .gatewayRunning)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        reload = try WhatsAppReloadWire(from: decoder)
    }
}

public struct WhatsAppPairingWire: Decodable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var pairingID: String
    public var status: String
    public var qrPayload: WhatsAppQRPayload?
    public var expiresAt: String?
    public var mode: String?
    public var allowedUsers: String?
    public var accountName: String?
    public var accountPhone: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case status, mode, error
        case pairingID = "pairing_id"
        case qrPayload = "qr_payload"
        case expiresAt = "expires_at"
        case allowedUsers = "allowed_users"
        case accountName = "account_name"
        case accountPhone = "account_phone"
    }

    public var description: String {
        "WhatsAppPairing(id: \(pairingID), status: \(status), qr: \(qrPayload == nil ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["pairingID": pairingID, "status": status], displayStyle: .struct)
    }
}

public struct WhatsAppAccount: Sendable, Equatable {
    public var name: String?
    public var phone: String?

    public init(name: String?, phone: String?) {
        self.name = name
        self.phone = phone
    }

    public var isEmpty: Bool { (name ?? "").isEmpty && (phone ?? "").isEmpty }
}

public struct WhatsAppReload: Sendable, Equatable {
    public var restartStarted: Bool
    public var restartBusy: Bool
    public var restartFailed: Bool

    public init(_ wire: WhatsAppReloadWire) {
        restartStarted = wire.restartStarted == true
        restartBusy = wire.restartBusy == true
        restartFailed = wire.restartError?.isEmpty == false
    }

    public var needsAttention: Bool { restartBusy || restartFailed }
}

public struct WhatsAppStatus: Sendable, Equatable {
    public var isEnabled: Bool
    public var isPaired: Bool
    public var mode: WhatsAppMode?
    public var allowedUsers: String
    public var account: WhatsAppAccount
    public var reload: WhatsAppReload

    public init(_ wire: WhatsAppStatusWire) {
        isEnabled = wire.enabled
        isPaired = wire.paired
        mode = WhatsAppMode(wire: wire.mode)
        allowedUsers = wire.allowedUsers ?? ""
        account = WhatsAppAccount(name: wire.accountName, phone: wire.accountPhone)
        reload = WhatsAppReload(wire.reload)
    }
}

public enum WhatsAppFailure: Sendable, Equatable {
    case anotherPairingActive
    case invalidSettings
    case pairingFailed
    case unavailable
}

public enum WhatsAppPairingState: Sendable, Equatable {
    case idle
    case starting(pairingID: String?)
    case showingQR(pairingID: String, qr: WhatsAppQRPayload)
    case connecting(pairingID: String)
    case connected(pairingID: String, account: WhatsAppAccount)
    case failed(WhatsAppFailure)
    case expired

    public var pairingID: String? {
        switch self {
        case .starting(let id): id
        case .showingQR(let id, _), .connecting(let id), .connected(let id, _): id
        case .idle, .failed, .expired: nil
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .showingQR, .connecting: true
        case .idle, .connected, .failed, .expired: false
        }
    }

    public var qr: WhatsAppQRPayload? {
        if case .showingQR(_, let qr) = self { qr } else { nil }
    }
}

public enum WhatsAppPairingEvent: Sendable {
    case startRequested
    case polled(WhatsAppPairingWire)
    case pairingGone
    case requestFailed(WhatsAppFailure)
    case cancelled
    case leftForeground
}

public enum WhatsAppPairingMachine {
    public static func reduce(_ state: WhatsAppPairingState, _ event: WhatsAppPairingEvent) -> WhatsAppPairingState {
        switch event {
        case .startRequested:
            return .starting(pairingID: nil)
        case .polled(let pairing):
            guard state.isActive else { return state }
            return next(pairing)
        case .pairingGone:
            return state.isActive ? .expired : state
        case .requestFailed(let failure):
            return state.isActive ? .failed(failure) : state
        case .cancelled, .leftForeground:
            return state.isActive ? .idle : state
        }
    }

    private static func next(_ pairing: WhatsAppPairingWire) -> WhatsAppPairingState {
        let id = pairing.pairingID
        switch pairing.status {
        case "starting":
            return .starting(pairingID: id)
        case "waiting":
            guard let qr = pairing.qrPayload, !qr.value.isEmpty else { return .connecting(pairingID: id) }
            return .showingQR(pairingID: id, qr: qr)
        case "connected":
            return .connected(pairingID: id, account: WhatsAppAccount(name: pairing.accountName, phone: pairing.accountPhone))
        case "expired":
            return .expired
        case "cancelled":
            return .idle
        default:
            return .failed(.pairingFailed)
        }
    }
}

public struct WhatsAppService: Sendable {
    static let invalidCode = 4111
    static let notFoundCode = 4113
    static let activePairingCode = 4119
    public static let invalidSettingsReason = "invalid_settings"

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status(profile: String) async throws -> WhatsAppStatus {
        try await statusCall("messaging.whatsapp.status", profile: profile)
    }

    public func startPairing(profile: String, mode: WhatsAppMode, allowedUsers: String, resetSession: Bool) async throws -> WhatsAppPairingWire {
        try await pairing("messaging.whatsapp.pair.start", profile: profile, [
            "mode": .string(mode.rawValue),
            "allowed_users": .string(allowedUsers),
            "reset_session": .bool(resetSession),
        ])
    }

    public func pairingStatus(profile: String, pairingID: String) async throws -> WhatsAppPairingWire {
        try await pairing("messaging.whatsapp.pair.status", profile: profile, ["pairing_id": .string(pairingID)])
    }

    public func cancelPairing(profile: String, pairingID: String) async throws {
        do {
            _ = try await gateway.scoped("messaging.whatsapp.pair.cancel", profile: profile, ["pairing_id": .string(pairingID)])
        } catch {
            throw Self.surface(error)
        }
    }

    public func applyPairing(profile: String, pairingID: String, mode: WhatsAppMode, allowedUsers: String) async throws -> WhatsAppReload {
        do {
            let result = try await gateway.scoped("messaging.whatsapp.pair.apply", profile: profile, [
                "pairing_id": .string(pairingID),
                "mode": .string(mode.rawValue),
                "allowed_users": .string(allowedUsers),
            ])
            return WhatsAppReload(try gateway.decoded(WhatsAppReloadWire.self, result))
        } catch {
            throw Self.surface(error)
        }
    }

    public func unpair(profile: String) async throws -> WhatsAppStatus {
        try await statusCall("messaging.whatsapp.unpair", profile: profile)
    }

    public func configure(profile: String, mode: WhatsAppMode, allowedUsers: String) async throws -> WhatsAppStatus {
        try await statusCall("messaging.whatsapp.configure", profile: profile, [
            "mode": .string(mode.rawValue),
            "allowed_users": .string(allowedUsers),
        ])
    }

    private func statusCall(_ method: String, profile: String, _ params: [String: JSONValue] = [:]) async throws -> WhatsAppStatus {
        do {
            let result = try await gateway.scoped(method, profile: profile, params)
            return WhatsAppStatus(try gateway.decoded(WhatsAppStatusWire.self, result))
        } catch {
            throw Self.surface(error)
        }
    }

    private func pairing(_ method: String, profile: String, _ params: [String: JSONValue]) async throws -> WhatsAppPairingWire {
        do {
            let result = try await gateway.scoped(method, profile: profile, params)
            return try gateway.decoded(WhatsAppPairingWire.self, result)
        } catch {
            throw Self.surface(error)
        }
    }

    private static func surface(_ error: any Error) -> any Error {
        guard case GatewayTransportError.rpc(let rpc) = error else { return BotsError.surface(error) }
        switch rpc.code {
        case invalidCode: return BotsError.rejected(reason: invalidSettingsReason)
        case notFoundCode: return BotsError.notFound
        case activePairingCode: return BotsError.conflict
        default: return BotsError.surface(error)
        }
    }
}

extension WhatsAppFailure {
    public init(_ error: any Error) {
        switch BotsError.classify(error) {
        case .conflict: self = .anotherPairingActive
        case .rejected(reason: WhatsAppService.invalidSettingsReason): self = .invalidSettings
        case .rejected: self = .pairingFailed
        default: self = .unavailable
        }
    }
}
