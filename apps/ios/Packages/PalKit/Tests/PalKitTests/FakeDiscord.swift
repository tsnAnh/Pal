import Foundation
import PalConnect
import PalProtocol
import Testing

actor FakeDiscord: DiscordSetupGateway {
    var app: Bool
    var lists: [[DiscordGuild]]
    var existing: DiscordInstalled?
    var installResult: Result<DiscordInstallOutcome, SetupStatusError>
    var ownerResult: Result<DiscordInstallOutcome, SetupStatusError> = .success(.installed(wizardInstalled))
    var tokenResult: Result<Void, SetupStatusError> = .success(())
    var reconnectResult: Result<DiscordInstalled, SetupStatusError> = .success(wizardInstalled)
    private(set) var reconnects: [String] = []
    var accessResult: Result<[ChatChannelAccessWire], SetupStatusError> = .success([])
    private(set) var checks: [String] = []
    private(set) var savedTokens: [String] = []
    private(set) var installs: [String] = []
    private(set) var confirmedOwners: [[String]] = []
    private var silent: Set<String> = []
    private var polls = 0

    init(
        app: Bool, lists: [[DiscordGuild]] = [[]], existing: DiscordInstalled? = nil,
        installResult: Result<DiscordInstallOutcome, SetupStatusError> = .success(.installed(wizardInstalled))
    ) {
        self.app = app
        self.lists = lists
        self.existing = existing
        self.installResult = installResult
    }

    func setInstall(_ result: Result<DiscordInstallOutcome, SetupStatusError>) { installResult = result }

    func setOwner(_ result: Result<DiscordInstallOutcome, SetupStatusError>) { ownerResult = result }

    func setToken(_ result: Result<Void, SetupStatusError>) { tokenResult = result }

    func setReconnect(_ result: Result<DiscordInstalled, SetupStatusError>) { reconnectResult = result }

    func reconnect(in guild: DiscordGuild) throws -> DiscordInstalled {
        reconnects.append(guild.id)
        return try reconnectResult.get()
    }

    func setAccess(_ result: Result<[ChatChannelAccessWire], SetupStatusError>) { accessResult = result }

    func channelAccess(in guild: DiscordGuild) async throws -> [ChatChannelAccessWire] {
        checks.append(guild.id)
        await hush("channelAccess")
        return try accessResult.get()
    }

    func silence(_ calls: Set<String>) { silent = calls }

    private func hush(_ call: String) async {
        if silent.contains(call) { await neverAnswers() }
    }

    func appExists() async -> Bool {
        await hush("appExists")
        return app
    }

    func saveToken(_ token: String) throws {
        try tokenResult.get()
        savedTokens.append(token)
        app = true
    }

    func servers() -> [DiscordGuild] {
        defer { polls += 1 }
        return lists[min(polls, lists.count - 1)]
    }

    func inviteURL() -> URL { DiscordSetupPlan.inviteURL(clientID: "101010")! }

    func existingInstall(in guilds: [DiscordGuild]) -> DiscordInstalled? { existing }

    func install(in guild: DiscordGuild) async throws -> DiscordInstallOutcome {
        installs.append(guild.id)
        await hush("install")
        return try installResult.get()
    }

    func confirmOwner(_ userID: String, in guild: DiscordGuild) throws -> DiscordInstallOutcome {
        confirmedOwners.append([userID, guild.id])
        return try ownerResult.get()
    }
}

let studio = DiscordGuild(id: "222", name: "Studio")
let wizardInstalled = studioInstall(ChatAdapterStatusWire(state: .online))

func studioInstall(_ adapter: ChatAdapterStatusWire?) -> DiscordInstalled {
    DiscordInstalled(guildID: "222", guildName: "Studio", channelID: "900", channelName: "ada", adapter: adapter)
}

@MainActor
func discordWizard(_ fake: FakeDiscord, attempts: Int = 4) -> DiscordSetupModel {
    DiscordSetupModel(displayName: "Ada", gateway: fake, timing: .init(interval: .milliseconds(1), attempts: attempts, limits: quickLimits))
}
