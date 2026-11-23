import Foundation
import PalProtocol
import PalTransport

public struct DiscordGuild: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DiscordServers: Sendable, Equatable {
    public var guilds: [DiscordGuild]
    public var allowed: [String]
    public var readOnly: Bool

    public init(guilds: [DiscordGuild], allowed: [String] = [], readOnly: Bool = true) {
        self.guilds = guilds
        self.allowed = allowed
        self.readOnly = readOnly
    }
}

extension ConnectAppsService {
    public func saveDiscordToken(_ verification: SetupVerification) async throws -> String? {
        guard let item = verification.items["token"] else {
            await discardVerified(verification)
            throw ConnectAppsError.oauthClient(.saveFailed)
        }
        do {
            let reply = try await discordCall("connectors.discord.token", ["item": .string(item)])
            await discardVerified(verification)
            return reply["bot_name"]?.stringValue
        } catch {
            await discardVerified(verification)
            throw error
        }
    }

    func discordCall(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error else { throw ConnectAppsError.oauthClient(.unreachable) }
            throw SetupStatusError(DiscordFlow.refusal(rpc, method: method))
        }
    }

    public func discordServers() async throws -> DiscordServers {
        let reply = try await discordCall("connectors.discord.guilds", [:])
        return DiscordServers(
            guilds: try decodeList(reply, key: "guilds", as: DiscordGuild.self),
            allowed: (reply["allowed"]?.arrayValue ?? []).compactMap(\.stringValue),
            readOnly: reply["read_only"]?.boolValue ?? true
        )
    }

    public func saveDiscord(guildIDs: [String], readOnly: Bool) async throws {
        _ = try await discordCall(
            "connectors.discord.save", ["guild_ids": .array(guildIDs.sorted().map { .string($0) }), "read_only": .bool(readOnly)]
        )
    }
}
