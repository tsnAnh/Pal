import Foundation
import PalConnect
import PalProtocol

actor ScriptedDiscordSetup: DiscordSetupGateway {
    static let argument = "-hermes-test-discord-wizard"
    static let appReadyArgument = "-hermes-test-discord-app-ready"
    static let needsOwnerArgument = "-hermes-test-discord-needs-owner"
    static let offlineArgument = "-hermes-test-discord-offline"
    static let mutedArgument = "-hermes-test-discord-muted"
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
    private var muted: Bool

    init(appReady: Bool, needsOwner: Bool, offline: Bool, muted: Bool, channel: String) {
        let ready = appReady || offline || muted
        app = ready
        self.offline = offline
        self.muted = muted
        self.needsOwner = needsOwner
        self.channel = channel
        listed = ready ? [Self.studio] : [Self.studio, Self.garage]
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
        if offline { return installed(Self.studio, adapter: ChatAdapterStatusWire(state: .notStarted)) }
        return muted ? installed(Self.studio) : nil
    }

    func reconnect(in guild: DiscordGuild) async throws -> DiscordInstalled {
        try await Task.sleep(for: .milliseconds(600))
        muted = false
        return installed(guild)
    }

    func channelAccess(in guild: DiscordGuild) -> [ChatChannelAccessWire] {
        [ChatChannelAccessWire(channelId: "900", name: channel, access: muted ? .cannotSend : .ok)]
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
