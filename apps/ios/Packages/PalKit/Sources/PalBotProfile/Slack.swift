import Foundation
import PalProtocol
import PalTransport

public enum SlackConnection: Sendable, Equatable, Codable {
    case notConnected
    case starting
    case connected
    case failed

    public init(_ wire: SlackStatusWire) {
        if wire.restartError?.isEmpty == false {
            self = .failed
        } else if !wire.configured {
            self = .notConnected
        } else {
            self = Self.configured(wire)
        }
    }

    private static func configured(_ wire: SlackStatusWire) -> SlackConnection {
        switch wire.state {
        case "connected": .connected
        case "not_configured", "disabled": .notConnected
        case "startup_failed", "disconnected", "paused": .failed
        case "fatal", "retrying": wire.errorCode?.isEmpty == false ? .failed : .starting
        case "connecting", "pending_restart", "gateway_stopped": .starting
        default: wire.enabled ? (wire.gatewayRunning ? .starting : .failed) : .notConnected
        }
    }

    public var isSettled: Bool {
        switch self {
        case .starting: false
        case .notConnected, .connected, .failed: true
        }
    }

    public var allowsTokenUpdate: Bool {
        switch self {
        case .failed, .connected: true
        case .notConnected, .starting: false
        }
    }
}

public struct SlackFailureReason: Sendable, Equatable, Codable {
    public let code: String
    public let message: String

    public init?(errorCode: String?, neededScope: String?, providedScope: String?) {
        guard let code = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        self.code = code
        let needed = Self.plainList(neededScope)
        switch code {
        case "missing_scope":
            if let needed {
                let token = needed.split(separator: ",").contains("connections:write") ? "app" : "bot"
                let has = Self.plainList(providedScope).map { " It has: \($0)." } ?? ""
                message = "The \(token) token is missing the \(needed) scope.\(has) Add it to your Slack app, then update the token."
            } else {
                message = "A Slack scope is missing. Add it to your Slack app, then update the token."
            }
        case "invalid_auth":
            message = "Slack didn't accept a token. Check the bot token and the app token, then update them."
        case "token_revoked":
            message = "A Slack token was revoked. Create a new token in your Slack app and update it."
        case "account_inactive":
            message = "The Slack account behind these tokens is inactive. Use tokens from an active account."
        case "not_authed":
            message = "Slack didn't receive a token. Update the tokens and try again."
        default:
            message = Self.plainList(code).map { "Slack said: \($0)" } ?? "Slack turned down the connection."
        }
    }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_,.-")

    static func plainWord(_ raw: String) -> String? {
        plainList(raw)?.replacingOccurrences(of: "_", with: " ")
    }

    private static func plainList(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200,
              text.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }
}

public struct SlackStatus: Sendable, Equatable, Codable {
    public static let checkFailedDetail = "Couldn't check Slack's status. Try again."

    public let connection: SlackConnection
    public let failure: SlackFailureReason?
    public let state: String?
    public let detail: String?

    public init(connection: SlackConnection, failure: SlackFailureReason? = nil, state: String? = nil, detail: String? = nil) {
        self.connection = connection
        self.failure = failure
        self.state = state
        self.detail = detail
    }

    public init(_ wire: SlackStatusWire) {
        let connection = SlackConnection(wire)
        let failure = connection == .failed
            ? SlackFailureReason(errorCode: wire.errorCode, neededScope: wire.neededScope, providedScope: wire.providedScope)
            : nil
        self.connection = connection
        self.failure = failure
        state = wire.state
        detail = connection == .failed ? failure?.message ?? Self.failedDetail(wire) : nil
    }

    public static func stalled(last: SlackStatus, botName: String) -> SlackStatus {
        SlackStatus(
            connection: .failed, state: last.state,
            detail: "Slack hasn't started for \(botName). Last status: \(stateLabel(last.state))."
        )
    }

    public static let unreachable = SlackStatus(connection: .failed, detail: checkFailedDetail)

    private static func failedDetail(_ wire: SlackStatusWire) -> String {
        if wire.restartError?.isEmpty == false { return "Pal couldn't restart the bot to apply the Slack connection. Try again." }
        switch wire.state {
        case "disconnected": return "Slack disconnected. Try again."
        case "paused": return "Slack was paused after repeated failures. Try again, or update the tokens."
        case "startup_failed": return "Pal couldn't start Slack for this bot. Try again, or update the tokens."
        default: return "This bot isn't running, so Slack can't start. Try again."
        }
    }

    private static func stateLabel(_ state: String?) -> String {
        switch state {
        case nil, "": "no status yet"
        case "gateway_stopped": "the bot isn't running"
        case "pending_restart": "waiting for the bot to restart"
        case "connecting": "connecting"
        case "retrying": "retrying"
        case "fatal": "stopped with an error"
        case let other?: SlackFailureReason.plainWord(other) ?? "unknown"
        }
    }
}

public struct SlackTokenUpdate: Sendable, Equatable {
    public static let botPrefix = "xoxb-"
    public static let appPrefix = "xapp-"

    public let bot: SecretString?
    public let app: SecretString?

    public init?(bot: String, app: String) {
        let bot = bot.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bot.isEmpty || Self.isBot(bot), app.isEmpty || Self.isApp(app), !bot.isEmpty || !app.isEmpty else { return nil }
        self.bot = bot.isEmpty ? nil : SecretString(bot)
        self.app = app.isEmpty ? nil : SecretString(app)
    }

    public var isComplete: Bool { bot != nil && app != nil }

    public static func isBot(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(botPrefix) && trimmed.count > botPrefix.count && !trimmed.contains(where: \.isWhitespace)
    }

    public static func isApp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(appPrefix) && trimmed.count > appPrefix.count && !trimmed.contains(where: \.isWhitespace)
    }
}

public struct SlackManifest: Sendable, Equatable {
    public let botName: String
    public let createURL: URL
}

public struct SlackService: Sendable {
    public static let invalidTokensReason = "invalid_tokens"
    static let invalidTokensCode = 4101

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status(profile: String) async throws -> SlackStatus {
        do {
            let result = try await gateway.scoped("messaging.slack.status", profile: profile)
            return SlackStatus(try gateway.decoded(SlackStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func manifest(profile: String, displayName: String) async throws -> SlackManifest {
        do {
            let result = try await gateway.scoped("messaging.slack.manifest", profile: profile, ["display_name": .string(displayName)])
            let wire = try gateway.decoded(SlackManifestWire.self, result)
            guard let url = URL(string: wire.createURL), url.scheme == "https", url.host() == "api.slack.com" else {
                throw BotsError.invalidResponse
            }
            return SlackManifest(botName: wire.botName, createURL: url)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func connect(profile: String, tokens: SlackTokenUpdate) async throws -> SlackStatus {
        var params: [String: JSONValue] = [:]
        if let bot = tokens.bot { params["bot_token"] = .string(bot.reveal()) }
        if let app = tokens.app { params["app_token"] = .string(app.reveal()) }
        do {
            let result = try await gateway.scoped("messaging.slack.connect", profile: profile, params)
            return SlackStatus(try gateway.decoded(SlackStatusWire.self, result))
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.invalidTokensCode {
            throw BotsError.rejected(reason: Self.invalidTokensReason)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func disconnect(profile: String) async throws -> SlackStatus {
        do {
            let result = try await gateway.scoped("messaging.slack.disconnect", profile: profile)
            return SlackStatus(try gateway.decoded(SlackStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }
}
