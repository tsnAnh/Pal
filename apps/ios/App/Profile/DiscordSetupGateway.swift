import Foundation
import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol

struct DiscordSetupLiveGateway: DiscordSetupGateway {
    private static let slug = "discord"
    private static let provider = "discord"

    let service: ConnectAppsService
    let client: any ChatInstallClient
    let spec: BotAvatarSpec?

    private func runner() async throws -> DiscordFlowRunner {
        guard let entry = try await service.catalogEntry(slug: Self.slug) else {
            throw SetupStatusError(SetupStatus(code: "gateway_outdated", method: "connectors.catalog", subject: "Discord"))
        }
        return DiscordFlowRunner(service: service, entry: entry)
    }

    private func scope(_ guild: DiscordGuild) -> ChatInstallScope {
        ChatInstallScope(provider: Self.provider, workspace: guild.id)
    }

    private static func chatFailure(_ error: any Error) -> any Error {
        if error is CancellationError || error is SetupStatusError { return error }
        let known = ChatInstallClientError(error)
        let fault = known.fault
        return SetupStatusError(SetupStatus(
            code: known == .unsupported ? "gateway_outdated" : known.reason.rawValue, method: fault?.method, trace: fault?.trace.rawValue,
            gatewayVersion: fault?.gatewayVersion, subject: "Discord"
        ))
    }

    func appExists() async throws -> Bool {
        do {
            _ = try await service.discordServers()
            return true
        } catch let error as SetupStatusError where error.status.code.lowercased() == "needs_setup" {
            return false
        }
    }

    func saveToken(_ token: String) async throws {
        try await runner().saveToken(token)
    }

    func servers() async throws -> [DiscordGuild] {
        try await service.discordServers().guilds
    }

    func inviteURL() async throws -> URL {
        let links = try await runner().inviteLinks()
        guard let client = links.lazy.compactMap({ DiscordSetupPlan.clientID(inCatalogInvite: $0.url) }).first,
              let url = DiscordSetupPlan.inviteURL(clientID: client)
        else { throw SetupStatusError(SetupStatus(code: "gateway_outdated", method: "connectors.catalog", subject: "Discord")) }
        return url
    }

    func existingInstall(in guilds: [DiscordGuild]) async throws -> DiscordInstalled? {
        do {
            for guild in guilds {
                let result = try await client.status(scope(guild))
                if result.state.step == .ready { return await installed(guild, result) }
            }
            return nil
        } catch {
            throw Self.chatFailure(error)
        }
    }

    func reconnect(in guild: DiscordGuild) async throws -> DiscordInstalled {
        do {
            return await installed(guild, try await client.reconnect(scope(guild)))
        } catch {
            throw Self.chatFailure(error)
        }
    }

    func channelAccess(in guild: DiscordGuild) async throws -> [ChatChannelAccessWire] {
        do {
            return try await client.channelAccess(scope(guild))
        } catch {
            throw Self.chatFailure(error)
        }
    }

    func install(in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        do {
            if let spec { await ChatIconPusher(client: client, providerID: Self.provider).push(spec, onlyWhenInstalled: false) }
            let scope = scope(guild)
            try await resume(scope, from: client.status(scope).state)
            return try await outcome(of: client.status(scope), in: guild)
        } catch {
            throw Self.chatFailure(error)
        }
    }

    func confirmOwner(_ userID: String, in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        do {
            let scope = scope(guild)
            var current = try await client.status(scope)
            if current.state.step != .needsOwner {
                try await resume(scope, from: current.state)
                current = try await client.status(scope)
            }
            if current.state.step == .needsOwner {
                try await client.advance(
                    scope, ChatInstallAdvance(event: .ownerConfirmed, expectedRevision: current.state.revision, ownerMemberId: userID)
                )
                current = try await client.status(scope)
            }
            return try await outcome(of: current, in: guild)
        } catch {
            throw Self.chatFailure(error)
        }
    }

    private func resume(_ scope: ChatInstallScope, from state: ChatSetupStateWire) async throws {
        switch state.step {
        case .ready: break
        case .error: try await client.advance(scope, ChatInstallAdvance(event: .retry, expectedRevision: state.revision))
        default: try await client.begin(scope)
        }
    }

    private func outcome(of result: ChatInstallStatusResult, in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        switch result.state.step {
        case .ready:
            return .installed(await installed(guild, result))
        case .needsOwner:
            return .needsOwner
        case .error:
            let error = result.state.error ?? ChatSetupErrorWire(code: .installFailed, fix: .retry)
            let invite = try? await inviteURL()
            throw SetupStatusError(DiscordSetupPlan.failure(error, server: guild, invite: invite))
        default:
            throw SetupStatusError(DiscordSetupPlan.failure(
                ChatSetupErrorWire(code: .installFailed, fix: .retry), server: guild, invite: nil
            ))
        }
    }

    private func installed(_ guild: DiscordGuild, _ result: ChatInstallStatusResult) async -> DiscordInstalled {
        let space = try? await client.spaces(scope(guild)).first { $0.joined }
        return DiscordInstalled(
            guildID: guild.id, guildName: result.installation?.workspaceName ?? guild.name, channelID: space?.id, channelName: space?.name,
            adapter: result.adapter
        )
    }
}
