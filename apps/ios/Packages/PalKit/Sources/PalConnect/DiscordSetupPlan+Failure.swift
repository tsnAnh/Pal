import Foundation
import PalProtocol

extension DiscordSetupPlan {
    public static let inviteTimeoutCode = "invite_timeout"
    public static let notInServerCode = "bot_not_in_server"
    public static let missingPermissionCode = "missing_permission"
    static let method = "chat.install.advance"
    private static let portalURL = URL(string: "https://discord.com/developers/applications")!

    public static func reconnectFailed(_ status: SetupStatus) -> SetupStatus {
        var status = status
        status.actionTitle = String(localized: "Reconnect")
        return status
    }

    public static func notConnected(_ installed: DiscordInstalled) -> SetupStatus? {
        guard let adapter = installed.adapter else {
            return reconnectFailed(SetupStatus(code: "gateway_outdated", method: "chat.install.status", subject: "Discord"))
        }
        guard adapter.state != .online else { return nil }
        var status = SetupStatus(
            code: adapter.reason?.rawValue ?? adapter.state.rawValue, method: "chat.install.status", subject: "Discord", valueName: "token"
        )
        status.title = String(localized: "Discord is not connected")
        status.actionTitle = String(localized: "Reconnect")
        switch adapter.reason {
        case .invalidToken:
            status.reason = String(
                localized: """
                Discord did not accept the Pal app token. Reset it on the Bot page of the Pal app, \
                paste the new one under Discord in Connected apps, then reconnect.
                """
            )
            status.link = SetupLink(label: String(localized: "Open the developer portal"), url: portalURL)
        case .missingIntent:
            status.reason = String(
                localized: "Message Content is switched off on the Bot page of the Pal app. Switch it on and save, then reconnect."
            )
            status.link = SetupLink(label: String(localized: "Open the developer portal"), url: portalURL)
        case .missingPermission:
            status.reason = cannotView(channelLabel(installed.channelName))
            status.link = channelURL(installed).map { SetupLink(label: String(localized: "Open in Discord"), url: $0) }
        case .restartNeeded:
            status.reason = String(localized: "Restart Pal on your computer, then reconnect.")
        case .adapterOffline, .unknown, nil:
            status.reason = adapter.state == .connecting
                ? String(localized: "Your Pal is still connecting to Discord. Reconnect to try again.")
                : String(localized: "Your Pal is not connected to Discord right now. Reconnect to try again.")
        }
        return status
    }

    public static func channelWarnings(_ found: [ChatChannelAccessWire]?) -> [String] {
        guard let found else { return [String(localized: "Pal could not check its permissions in Discord.")] }
        return found.compactMap { channel in
            let label = channelLabel(channel.name)
            return switch channel.access {
            case .ok: nil
            case .cannotView: cannotView(label)
            case .cannotSend:
                String(localized: "Pal cannot send messages in \(label). Give the Pal role Send Messages there, then reconnect.")
            case .unknown: String(localized: "Pal could not check its permissions in \(label).")
            }
        }
    }

    private static func channelLabel(_ name: String?) -> String {
        name.map { "#\($0)" } ?? String(localized: "its channel")
    }

    private static func cannotView(_ channel: String) -> String {
        String(localized: "Pal cannot see \(channel). Give the Pal role View Channel there, then reconnect.")
    }

    public static func inviteTimeout(server: String?, invite: URL?) -> SetupStatus {
        var status = SetupStatus(code: inviteTimeoutCode, method: "connectors.discord.guilds", subject: "Discord")
        status.title = String(localized: "Pal is not in the server yet")
        let name = server ?? String(localized: "your server")
        status.reason = String(localized: "Pal is not in \(name) after 60 s. Open the invite link again and press Authorize.")
        status.actionTitle = String(localized: "Retry")
        status.link = invite.map { SetupLink(label: String(localized: "Open the invite link"), url: $0) }
        return status
    }

    public static func failure(_ error: ChatSetupErrorWire, server: DiscordGuild?, invite: URL?) -> SetupStatus {
        let name = server?.name ?? String(localized: "your server")
        let reason = error.reason ?? ""
        var status = SetupStatus(code: reason.isEmpty ? error.code.rawValue : reason, method: method, subject: "Discord", valueName: "token")
        status.actionTitle = String(localized: "Retry")
        switch reason {
        case "invalid_token", "no_token":
            status.title = String(localized: "Discord did not accept the Pal app token")
            status.reason = String(localized: "Reset the token on the Bot page of the Pal app, then paste the new one.")
            status.actionTitle = String(localized: "Paste the token again")
        case notInServerCode:
            return inviteTimeout(server: server?.name, invite: invite)
        case missingPermissionCode:
            status.title = String(localized: "Pal is missing a permission")
            let list = error.permissions.isEmpty ? String(localized: "the needed") : error.permissions.joined(separator: ", ")
            status.reason = String(
                localized: "Pal is missing the \(list) permission in \(name). Give the Pal role that permission in Server Settings, then retry."
            )
            status.link = server.flatMap { URL(string: "https://discord.com/channels/\($0.id)") }
                .map { SetupLink(label: String(localized: "Open server settings"), url: $0) }
        case "missing_intent":
            status.title = String(localized: "Message Content is switched off")
            status.reason = String(
                localized: """
                Open the Pal app in the developer portal, go to Bot, switch on Message Content \
                under Privileged Gateway Intents and save, then retry.
                """
            )
            status.link = SetupLink(label: String(localized: "Open the developer portal"), url: portalURL)
        case "restart_needed":
            status.title = String(localized: "Your Pal needs a restart")
            status.reason = String(localized: "Restart Pal on your computer, then retry.")
        case "adapter_offline":
            status.title = String(localized: "Discord did not connect")
            status.reason = String(localized: "Your Pal could not connect to Discord in time. Retry in a moment.")
        case "rate_limited":
            status.title = String(localized: "Discord asked Pal to wait")
            status.reason = error.retryAfterSeconds.map { String(localized: "Discord is limiting requests. Retry in \($0) s.") }
                ?? String(localized: "Discord is limiting requests. Retry in a moment.")
        default:
            let unreachable = error.code == .providerUnreachable
            status.title = unreachable ? String(localized: "Pal could not reach Discord") : String(localized: "Discord stopped the setup")
            status.reason = Self.describe(reason: reason, server: name)
        }
        return status
    }

    private static func describe(reason: String, server: String) -> String {
        switch reason {
        case "choose_server": String(localized: "Pal is in more than one server. Go back and pick the one for this bot.")
        case "bad_server_id": String(localized: "Discord did not recognise that server. Go back and pick it again.")
        case "route_conflict": String(localized: "Another bot already uses a channel in \(server). Remove that bot's Discord link, then retry.")
        case "no_record": String(localized: "Pal lost the record of this setup. Retry to create the channel again.")
        case "network": String(localized: "Pal could not reach Discord. Check your connection, then retry.")
        case let value where value.hasPrefix("http_"):
            String(localized: "Discord answered with an error (\(String(value.dropFirst(5)))). Retry in a moment.")
        default: String(localized: "Discord did not finish the setup. Retry in a moment.")
        }
    }
}
