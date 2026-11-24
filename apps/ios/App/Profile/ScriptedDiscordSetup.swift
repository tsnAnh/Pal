import Foundation
import PalConnect

actor ScriptedDiscordSetup: DiscordSetupGateway {
    static let argument = "-hermes-test-discord-wizard"
    static let appReadyArgument = "-hermes-test-discord-app-ready"
    static let timing = DiscordSetupModel.Timing(interval: .milliseconds(300), attempts: 30)

    private static let studio = DiscordGuild(id: "222", name: "Studio")
    private static let garage = DiscordGuild(id: "333", name: "Garage")
    private static let atelier = DiscordGuild(id: "444", name: "Atelier")
    private static let newServerAfterPolls = 5

    private var app: Bool
    private var polls = 0
    private let channel: String
    private let listed: [DiscordGuild]

    init(appReady: Bool, channel: String) {
        app = appReady
        self.channel = channel
        listed = appReady ? [Self.studio] : [Self.studio, Self.garage]
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

    func existingInstall(in guilds: [DiscordGuild]) -> DiscordInstalled? { nil }

    func install(in guild: DiscordGuild) async throws -> DiscordInstalled {
        try await Task.sleep(for: .milliseconds(600))
        return DiscordInstalled(guildID: guild.id, guildName: guild.name, channelID: "900", channelName: channel)
    }
}
