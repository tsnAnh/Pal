import PalProtocol
import PalTransport

struct ScriptedDiscord {
    static let botName = "Scripted Bot"
    static let applicationID = "101010101010101010"
    static let guilds: [JSONValue] = [["id": "111", "name": "Team"], ["id": "222", "name": "Friends"]]

    private var tokenSaved = false
    private var allowed: [String] = []
    private var readOnly = true
    private var connected = false

    mutating func handle(_ method: String, _ params: JSONValue, vault: [String: String]) throws -> JSONValue {
        switch method {
        case "connectors.discord.token":
            guard let token = vault[params["item"]?.stringValue ?? ""], !token.contains("rejected") else {
                throw Self.failure(4000, "INVALID_TOKEN")
            }
            tokenSaved = true
            return ["bot_name": .string(Self.botName), "application_id": .string(Self.applicationID)]
        case "connectors.discord.guilds":
            guard tokenSaved else { throw Self.failure(4090, "NEEDS_SETUP") }
            return ["guilds": .array(Self.guilds), "allowed": .array(allowed.map(JSONValue.string)), "read_only": .bool(readOnly)]
        default:
            let ids = (params["guild_ids"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard tokenSaved, !ids.isEmpty else { throw Self.failure(4000, "INVALID_PARAMS") }
            allowed = ids
            readOnly = params["read_only"]?.boolValue ?? true
            connected = true
            return ["tools": 11, "read_only": .bool(readOnly), "guild_ids": .array(ids.map(JSONValue.string))]
        }
    }

    func row() -> JSONValue {
        let step = connected ? "access" : tokenSaved ? "invite" : "bot"
        return [
            "slug": "discord", "name": "Discord", "category": "Communication", "icon": "plugin_glyph", "method": "bot_token_stdio",
            "verified": true, "status": .string(connected ? "connected" : "not_connected"),
            "setup_guide": guide(), "setup_progress": ScriptedSetupGuides.progress(step, saved: tokenSaved ? ["token"] : []),
        ]
    }

    private func guide() -> JSONValue {
        let invite = "https://discord.com/oauth2/authorize?client_id=\(Self.applicationID)&scope=bot&permissions="
        let links: [JSONValue] = tokenSaved
            ? [["label": "Invite the bot to read", "url": .string(invite + "66560")],
               ["label": "Invite the bot to read and post", "url": .string(invite + "68672")]]
            : []
        return ["steps": [
            Self.step("bot", "open_page", "Create your Discord bot",
                      links: [["label": "Open Discord Developer Portal", "url": "https://discord.com/developers/applications"]]),
            Self.step("token", "paste", "Paste your bot token",
                      fields: [["id": "token", "label": "Bot token", "secret": true, "prefixes": [], "suffix": .null]], check: "discord_bot"),
            Self.step("invite", "open_page", "Add the bot to your servers", links: links),
            Self.step("servers", "server_picker", "Choose the servers Pal may use"),
            Self.step("access", "access", "Choose what Pal may do"),
        ]]
    }

    private static func step(
        _ id: String, _ kind: String, _ title: String, links: [JSONValue] = [], fields: [JSONValue] = [], check: String? = nil
    ) -> JSONValue {
        [
            "id": .string(id), "kind": .string(kind), "title": .string(title), "body": "", "links": .array(links), "copies": [],
            "fields": .array(fields), "check": check.map(JSONValue.string) ?? JSONValue.null,
        ]
    }

    private static func failure(_ code: Int, _ reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }
}
