import Foundation
import PalProtocol
import PalTransport

public enum TelegramConnection: Sendable, Equatable {
    case notConnected
    case starting
    case connected
    case restartNeeded
    case failed

    public init(_ wire: TelegramStatusWire) {
        if wire.restartBusy == true {
            self = .restartNeeded
        } else if wire.restartError?.isEmpty == false {
            self = .failed
        } else if !wire.configured {
            self = .notConnected
        } else {
            self = Self.configured(
                state: wire.state, hasErrorCode: wire.errorCode?.isEmpty == false, restartStarted: wire.restartStarted == true
            )
        }
    }

    private static func configured(state: String?, hasErrorCode: Bool, restartStarted: Bool) -> TelegramConnection {
        switch state {
        case "connected": .connected
        case "not_configured", "disabled": .notConnected
        case "pending_restart", "gateway_stopped": restartStarted ? .starting : .restartNeeded
        case "startup_failed": .failed
        case "fatal", "retrying": hasErrorCode ? .failed : .starting
        default: .starting
        }
    }

    public var isSettled: Bool {
        switch self {
        case .starting: false
        case .notConnected, .connected, .restartNeeded, .failed: true
        }
    }

    public var allowsTokenUpdate: Bool {
        switch self {
        case .failed, .connected: true
        case .notConnected, .starting, .restartNeeded: false
        }
    }
}

public struct TelegramFailureReason: Sendable, Equatable {
    public static let invalidToken = "Telegram doesn't accept this token. It may be wrong or revoked. Create a new one with @BotFather and update it."
    public static let network = "Hermes can't reach Telegram right now. Check the connection; it keeps trying."
    public static let conflict = "Another copy of this bot is using the same token. Stop it, or create a new token with @BotFather and update it."
    public static let generic = "Telegram turned down the connection."

    public let code: String
    public let message: String

    public init?(errorCode: String?) {
        guard let code = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        self.code = code
        switch code {
        case "telegram_auth_error": message = Self.invalidToken
        case "telegram_network_error", "telegram_connect_error": message = Self.network
        case "telegram_polling_conflict": message = Self.conflict
        default: message = Self.generic
        }
    }
}

public struct TelegramStatus: Sendable, Equatable {
    public let connection: TelegramConnection
    public let failure: TelegramFailureReason?
    public let allowedUsersSet: Bool

    public init(connection: TelegramConnection, failure: TelegramFailureReason? = nil, allowedUsersSet: Bool = true) {
        self.connection = connection
        self.failure = failure
        self.allowedUsersSet = allowedUsersSet
    }

    public init(_ wire: TelegramStatusWire) {
        let connection = TelegramConnection(wire)
        self.connection = connection
        failure = connection == .failed ? TelegramFailureReason(errorCode: wire.errorCode) : nil
        allowedUsersSet = wire.allowedUsersSet ?? true
    }
}

public struct TelegramTokenUpdate: Sendable, Equatable {
    public let token: SecretString

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isWellFormed(trimmed) else { return nil }
        token = SecretString(trimmed)
    }

    public static func isWellFormed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = parts.first, let secret = parts.last else { return false }
        return !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
            && secret.count >= 30 && secret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

public struct TelegramService: Sendable {
    public static let invalidTokenReason = "invalid_token"
    public static let networkReason = "network"
    static let invalidTokenCode = 4101
    static let networkCode = 5103

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status(profile: String) async throws -> TelegramStatus {
        do {
            let result = try await gateway.scoped("messaging.telegram.status", profile: profile)
            return TelegramStatus(try gateway.decoded(TelegramStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func connect(profile: String, token: TelegramTokenUpdate) async throws -> TelegramStatus {
        let params: [String: JSONValue] = ["bot_token": .string(token.token.reveal())]
        do {
            let result = try await gateway.scoped("messaging.telegram.connect", profile: profile, params)
            return TelegramStatus(try gateway.decoded(TelegramStatusWire.self, result))
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.invalidTokenCode {
            throw BotsError.rejected(reason: Self.invalidTokenReason)
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.networkCode {
            throw BotsError.rejected(reason: Self.networkReason)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func disconnect(profile: String) async throws -> TelegramStatus {
        do {
            let result = try await gateway.scoped("messaging.telegram.disconnect", profile: profile)
            return TelegramStatus(try gateway.decoded(TelegramStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }
}
