import Foundation
import PalConnect
import PalProtocol
import Testing

private actor FakeDiscord: DiscordSetupGateway {
    var app: Bool
    var lists: [[DiscordGuild]]
    var existing: DiscordInstalled?
    var installResult: Result<DiscordInstalled, SetupStatusError>
    var tokenResult: Result<Void, SetupStatusError> = .success(())
    private(set) var savedTokens: [String] = []
    private(set) var installs: [String] = []
    private var polls = 0

    init(
        app: Bool, lists: [[DiscordGuild]] = [[]], existing: DiscordInstalled? = nil,
        installResult: Result<DiscordInstalled, SetupStatusError> = .success(wizardInstalled)
    ) {
        self.app = app
        self.lists = lists
        self.existing = existing
        self.installResult = installResult
    }

    func setInstall(_ result: Result<DiscordInstalled, SetupStatusError>) { installResult = result }

    func setToken(_ result: Result<Void, SetupStatusError>) { tokenResult = result }

    func appExists() -> Bool { app }

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

    func install(in guild: DiscordGuild) throws -> DiscordInstalled {
        installs.append(guild.id)
        return try installResult.get()
    }
}

private let studio = DiscordGuild(id: "222", name: "Studio")
private let garage = DiscordGuild(id: "333", name: "Garage")
private let wizardInstalled = DiscordInstalled(guildID: "222", guildName: "Studio", channelID: "900", channelName: "ada")

private func missingWebhooks() -> SetupStatusError {
    let error = ChatSetupErrorWire(code: .installFailed, fix: .retry, reason: "missing_permission", permissions: ["Manage Webhooks"])
    return SetupStatusError(DiscordSetupPlan.failure(error, server: studio, invite: nil))
}

@MainActor
private func model(_ fake: FakeDiscord, attempts: Int = 4) -> DiscordSetupModel {
    DiscordSetupModel(displayName: "Ada", gateway: fake, timing: .init(interval: .milliseconds(1), attempts: attempts))
}

@Suite("Discord setup wizard")
@MainActor
struct DiscordSetupWizardTests {
    @Test func theFiveStepListAndTheFirstScreenForTheFirstBot() async throws {
        let wizard = model(FakeDiscord(app: false))
        await wizard.load()
        await wizard.flow.start()
        #expect(wizard.stage == .flow)
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.startID)
        #expect(wizard.flow.engine.checklist.map(\.title) == [
            "Create the Pal app", "Paste its token", "Pick the server", "Invite Pal", "Create this bot's channel",
        ])
        #expect(wizard.flow.engine.current.primaryTitle == "Set up Pal in Discord")
        #expect(wizard.flow.engine.current.screenTitle == "Add Ada to Discord")
    }

    @Test func aGoodTokenMovesToTheServerListAndIsSavedOnce() async throws {
        let fake = FakeDiscord(app: false, lists: [[studio, garage]])
        let wizard = model(fake)
        await wizard.load()
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.tokenID)
        wizard.flow.setValue(discordFlowToken, for: "token")
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.serverID)
        #expect(await fake.savedTokens == [discordFlowToken])
        #expect(wizard.flow.engine.isPrimaryEnabled == false)
        guard case .switches(let groups) = wizard.flow.engine.current.kind else {
            Issue.record("not a server list")
            return
        }
        #expect(groups[0].switches.map(\.title) == ["Studio", "Garage", "Another server"])
        #expect(groups[0].switches.last?.subtitle == "Pal is not here yet")
    }

    @Test func aRefusedTokenStaysOnTheStepWithTheRefusal() async throws {
        let fake = FakeDiscord(app: false)
        await fake.setToken(.failure(SetupStatusError(SetupStatus(code: "invalid_token", subject: "Discord", valueName: "token"))))
        let wizard = model(fake)
        await wizard.load()
        await wizard.flow.performPrimary()
        wizard.flow.setValue(discordFlowToken, for: "token")
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.tokenID)
        #expect(wizard.flow.engine.failure?.kind == .vendorRefusedValue)
        #expect(await fake.savedTokens.isEmpty)
    }

    @Test func pickingAServerPalIsAlreadyInCreatesTheChannelAndEndsOnTheReadyScreen() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio, garage]])
        let wizard = model(fake)
        await wizard.load()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.serverID)
        wizard.flow.setSwitch("guild.222", true)
        wizard.flow.setSwitch("guild.333", true)
        #expect(wizard.flow.engine.isOn("guild.222") == false)
        await wizard.flow.performPrimary()
        #expect(await fake.installs == ["333"])
        #expect(wizard.flow.engine.isFinished)
        #expect(wizard.installed == wizardInstalled)
        guard case .success(let title, let body) = wizard.flow.engine.current.kind else {
            Issue.record("not the ready screen")
            return
        }
        #expect(title == "Ada is in Discord")
        #expect(body == "Write in #ada in Studio. Send /pal in a direct message to talk to any bot.")
        #expect(DiscordSetupPlan.channelURL(wizardInstalled)?.absoluteString == "https://discord.com/channels/222/900")
    }

    @Test func theInvitePollFindsTheNewServerAndCreatesTheChannelWithoutAnotherTap() async throws {
        let fake = FakeDiscord(app: true, lists: [[], [], [], [studio]])
        let wizard = model(fake)
        await wizard.load()
        #expect(wizard.flow.engine.isOn("new"))
        var opened: [URL] = []
        wizard.flow.openPage = { opened.append($0) }
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.inviteID)
        #expect(wizard.flow.engine.phase == .ready)
        await wizard.flow.performPrimary()
        #expect(opened.first?.absoluteString.contains("permissions=\(DiscordSetupPlan.invitePermissions)") == true)
        #expect(await fake.installs == ["222"])
        #expect(wizard.flow.engine.isFinished)
    }

    @Test func theInvitePollGivesUpAndOffersRetryAndTheInviteLink() async throws {
        let fake = FakeDiscord(app: true, lists: [[]])
        let wizard = model(fake, attempts: 3)
        await wizard.load()
        wizard.flow.openPage = { _ in }
        await wizard.flow.performPrimary()
        await wizard.flow.performPrimary()
        let failure = try #require(wizard.flow.engine.failure)
        #expect(failure.code == DiscordSetupPlan.inviteTimeoutCode)
        #expect(failure.reason == "Pal is not in your server after 60 s. Open the invite link again and press Authorize.")
        #expect(failure.actionTitle == "Retry")
        #expect(failure.link?.label == "Open the invite link")
        #expect(await fake.installs.isEmpty)
    }

    @Test func missingManageWebhooksShowsItsOwnReasonAndRetrySucceedsAfterTheFix() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio]], installResult: .failure(missingWebhooks()))
        let wizard = model(fake)
        await wizard.load()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.creatingID)
        await wizard.flow.performPrimary()
        let failure = try #require(wizard.flow.engine.failure)
        #expect(failure.reason == "Pal is missing the Manage Webhooks permission in Studio. Give the Pal role that permission in Server Settings, then retry.")
        #expect(failure.link?.label == "Open server settings")
        await fake.setInstall(.success(wizardInstalled))
        await wizard.flow.recover(from: failure)
        #expect(wizard.flow.engine.isFinished)
    }

    @Test func anyOtherFailureCarriesTheGatewaysRealReason() {
        func reason(_ code: String, permissions: [String] = [], retry: Int? = nil) -> String {
            let error = ChatSetupErrorWire(code: .installFailed, fix: .retry, reason: code, permissions: permissions, retryAfterSeconds: retry)
            return DiscordSetupPlan.failure(error, server: studio, invite: nil).reason
        }
        #expect(reason("http_503").contains("503"))
        #expect(reason("rate_limited", retry: 7).contains("7 s"))
        #expect(reason("route_conflict").contains("Studio"))
        #expect(reason("missing_intent").contains("Message Content"))
        #expect(reason("weird_thing") == "Discord reported: weird thing.")
        #expect(reason("missing_permission", permissions: ["Manage Channels", "Manage Webhooks"]).contains("Manage Channels, Manage Webhooks"))
    }

    @Test func theSecondBotGoesStraightToTheChannelStepAndOneTapFinishes() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio]])
        let wizard = model(fake)
        await wizard.load()
        await wizard.flow.start()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.creatingID)
        #expect(wizard.flow.engine.primaryAction == .work)
        #expect(wizard.flow.engine.current.primaryTitle == "Create Ada's channel")
        #expect(await fake.installs.isEmpty)
        await wizard.flow.performPrimary()
        #expect(await fake.installs == ["222"])
        #expect(wizard.flow.engine.isFinished)
    }

    @Test func resumeFollowsWhatTheGatewayAlreadyHolds() async throws {
        let done = model(FakeDiscord(app: true, lists: [[studio]], existing: wizardInstalled))
        await done.load()
        #expect(done.flow.engine.isFinished && done.installed == wizardInstalled)

        let many = model(FakeDiscord(app: true, lists: [[studio, garage]]))
        await many.load()
        #expect(many.flow.engine.current.id == DiscordSetupPlan.serverID)

        let fresh = model(FakeDiscord(app: false))
        await fresh.load()
        #expect(fresh.flow.engine.current.id == DiscordSetupPlan.startID)
    }

    @Test func aGatewayFailureWhileLoadingShowsItsReason() async throws {
        struct Down: DiscordSetupGateway {
            func appExists() async throws -> Bool { throw SetupStatusError(SetupStatus(code: "check_unavailable", subject: "Discord")) }
            func saveToken(_ token: String) async throws {}
            func servers() async throws -> [DiscordGuild] { [] }
            func inviteURL() async throws -> URL { URL(string: "https://discord.com")! }
            func existingInstall(in guilds: [DiscordGuild]) async throws -> DiscordInstalled? { nil }
            func install(in guild: DiscordGuild) async throws -> DiscordInstalled { wizardInstalled }
        }
        let wizard = DiscordSetupModel(displayName: "Ada", gateway: Down())
        await wizard.load()
        guard case .status(let status) = wizard.stage else {
            Issue.record("expected a status screen")
            return
        }
        #expect(status.code == "check_unavailable")
    }

    @Test func theWireErrorKeepsTheReasonPermissionsAndWait() throws {
        let json = #"{"code":"install_failed","fix":"retry","reason":"missing_permission","permissions":["Manage Webhooks"],"retry_after_seconds":3}"#
        let error = try JSONDecoder().decode(ChatSetupErrorWire.self, from: Data(json.utf8))
        #expect(error.reason == "missing_permission" && error.permissions == ["Manage Webhooks"] && error.retryAfterSeconds == 3)
        let legacy = try JSONDecoder().decode(ChatSetupErrorWire.self, from: Data(#"{"code":"install_failed","fix":"retry"}"#.utf8))
        #expect(legacy.reason == nil && legacy.permissions.isEmpty)
    }
}
