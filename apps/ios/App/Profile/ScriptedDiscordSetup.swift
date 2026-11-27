import Foundation
import PalConnect
import PalProtocol

actor ScriptedDiscordSetup: DiscordSetupGateway {
    static let argument = "-hermes-test-discord-wizard"
    static let appReadyArgument = "-hermes-test-discord-app-ready"
    static let needsOwnerArgument = "-hermes-test-discord-needs-owner"
    static let offlineArgument = "-hermes-test-discord-offline"
    static let timing = DiscordSetupModel.Timing(interval: .milliseconds(300), attempts: 30)

    private static let studio = DiscordGuild(id: "222", name: "Studio")
    private static let garage = DiscordGuild(id: "333", name: "Garage")
    private static let atelier = DiscordGuild(id: "444", name: "Atelier")
    private static let newServerAfterPolls = 5

    private var app: Bool
    private var polls = 0
    private let channel: String
    private let listed: [DiscordGuild]
    private let needsOwner: Bool
    private let offline: Bool

    init(appReady: Bool, needsOwner: Bool, offline: Bool, channel: String) {
        app = appReady || offline
        self.offline = offline
        self.needsOwner = needsOwner
        self.channel = channel
        listed = appReady || offline ? [Self.studio] : [Self.studio, Self.garage]
    }

    func appExists() -> Bool { app }

    func saveToken(_ token: String) {
        app = true
    }

    func servers() -> [DiscordGuild] {
        polls += 1
        return polls >= Self.newServerAfterPolls ? listed + [Self.atelier] : listed
    }

    func inviteURL() -> URL {
        DiscordSetupPlan.inviteURL(clientID: "101010") ?? URL(string: "https://discord.com")!
    }

    func existingInstall(in guilds: [DiscordGuild]) -> DiscordInstalled? {
        offline ? installed(Self.studio, adapter: ChatAdapterStatusWire(state: .notStarted)) : nil
    }

    func reconnect(in guild: DiscordGuild) async throws -> DiscordInstalled {
        try await Task.sleep(for: .milliseconds(600))
        return installed(guild)
    }

    func install(in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        try await Task.sleep(for: .milliseconds(600))
        return needsOwner ? .needsOwner : .installed(installed(guild))
    }

    func confirmOwner(_ userID: String, in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        try await Task.sleep(for: .milliseconds(600))
        return .installed(installed(guild))
    }

    private func installed(
        _ guild: DiscordGuild, adapter: ChatAdapterStatusWire = ChatAdapterStatusWire(state: .online)
    ) -> DiscordInstalled {
        DiscordInstalled(guildID: guild.id, guildName: guild.name, channelID: "900", channelName: channel, adapter: adapter)
    }
}
