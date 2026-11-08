import Foundation
import HermesProtocol
import HermesTransport

public enum SlackConnection: Sendable, Equatable {
    case notConnected
    case starting
    case connected
    case restartNeeded
    case failed

    public init(_ wire: SlackStatusWire) {
        if wire.restartBusy == true {
            self = .restartNeeded
        } else if wire.restartError?.isEmpty == false {
            self = .failed
        } else if !wire.configured {
            self = .notConnected
        } else {
            self = Self.configured(state: wire.state, restartStarted: wire.restartStarted == true)
        }
    }

    private static func configured(state: String?, restartStarted: Bool) -> SlackConnection {
        switch state {
        case "connected": .connected
        case "not_configured", "disabled": .notConnected
        case "pending_restart", "gateway_stopped": restartStarted ? .starting : .restartNeeded
        case "startup_failed": .failed
        default: .starting
        }
    }

    public var isSettled: Bool {
        switch self {
        case .starting: false
        case .notConnected, .connected, .restartNeeded, .failed: true
        }
    }
}

public struct SlackTokens: Sendable {
    public static let botPrefix = "xoxb-"
    public static let appPrefix = "xapp-"

    public let bot: String
    public let app: String

    public init?(bot: String, app: String) {
        let bot = bot.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isBot(bot), Self.isApp(app) else { return nil }
        self.bot = bot
        self.app = app
    }

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

    public func status(profile: String) async throws -> SlackConnection {
        do {
            let result = try await gateway.scoped("messaging.slack.status", profile: profile)
            return SlackConnection(try gateway.decoded(SlackStatusWire.self, result))
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

    public func connect(profile: String, tokens: SlackTokens) async throws -> SlackConnection {
        do {
            let result = try await gateway.scoped("messaging.slack.connect", profile: profile, [
                "bot_token": .string(tokens.bot),
                "app_token": .string(tokens.app),
            ])
            return SlackConnection(try gateway.decoded(SlackStatusWire.self, result))
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.invalidTokensCode {
            throw BotsError.rejected(reason: Self.invalidTokensReason)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func disconnect(profile: String) async throws -> SlackConnection {
        do {
            let result = try await gateway.scoped("messaging.slack.disconnect", profile: profile)
            return SlackConnection(try gateway.decoded(SlackStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }
}
