import Foundation
import PalProtocol

extension DiscordSetupPlan {
    public static let inviteTimeoutCode = "invite_timeout"
    public static let notInServerCode = "bot_not_in_server"
    public static let missingPermissionCode = "missing_permission"
    static let method = "chat.install.advance"
    private static let portalURL = URL(string: "https://discord.com/developers/applications")!

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
                localized: "Open the Pal app in the developer portal, go to Bot, switch on Message Content under Privileged Gateway Intents and save, then retry."
            )
            status.link = SetupLink(label: String(localized: "Open the developer portal"), url: portalURL)
        case "rate_limited":
            status.title = String(localized: "Discord asked Pal to wait")
            status.reason = error.retryAfterSeconds.map { String(localized: "Discord is limiting requests. Retry in \($0) s.") }
                ?? String(localized: "Discord is limiting requests. Retry in a moment.")
        default:
            status.title = error.code == .providerUnreachable ? String(localized: "Pal could not reach Discord") : String(localized: "Discord stopped the setup")
            status.reason = Self.describe(reason: reason, code: error.code, server: name)
        }
        return status
    }

    private static func describe(reason: String, code: ChatSetupErrorCode, server: String) -> String {
        switch reason {
        case "choose_server": String(localized: "Pal is in more than one server. Go back and pick the one for this bot.")
        case "bad_server_id": String(localized: "Discord did not recognise that server. Go back and pick it again.")
        case "route_conflict": String(localized: "Another bot already uses a channel in \(server). Remove that bot's Discord link, then retry.")
        case "no_record": String(localized: "Pal lost the record of this setup. Retry to create the channel again.")
        case "network": String(localized: "Pal could not reach Discord. Check your connection, then retry.")
        case let value where value.hasPrefix("http_"):
            String(localized: "Discord answered with an error (\(value.dropFirst(5))). Retry in a moment.")
        case let value where !value.isEmpty: String(localized: "Discord reported: \(value.replacingOccurrences(of: "_", with: " ")).")
        default: String(localized: "Discord reported \(code.rawValue.replacingOccurrences(of: "_", with: " ")).")
        }
    }
}
