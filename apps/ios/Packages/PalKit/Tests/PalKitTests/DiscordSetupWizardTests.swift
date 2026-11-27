import Foundation
import PalConnect
import PalProtocol
import Testing

private actor FakeDiscord: DiscordSetupGateway {
    var app: Bool
    var lists: [[DiscordGuild]]
    var existing: DiscordInstalled?
    var installResult: Result<DiscordInstallOutcome, SetupStatusError>
    var ownerResult: Result<DiscordInstallOutcome, SetupStatusError> = .success(.installed(wizardInstalled))
    var tokenResult: Result<Void, SetupStatusError> = .success(())
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

private let studio = DiscordGuild(id: "222", name: "Studio")
private let garage = DiscordGuild(id: "333", name: "Garage")
private let wizardInstalled = DiscordInstalled(guildID: "222", guildName: "Studio", channelID: "900", channelName: "ada")

private func missingWebhooks() -> SetupStatusError {
    let error = ChatSetupErrorWire(code: .installFailed, fix: .retry, reason: "missing_permission", permissions: ["Manage Webhooks"])
    return SetupStatusError(DiscordSetupPlan.failure(error, server: studio, invite: nil))
}

@MainActor
private func model(_ fake: FakeDiscord, attempts: Int = 4) -> DiscordSetupModel {
    DiscordSetupModel(displayName: "Ada", gateway: fake, timing: .init(interval: .milliseconds(1), attempts: attempts, limits: quickLimits))
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
        await fake.setInstall(.success(.installed(wizardInstalled)))
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
        #expect(reason("missing_permission", permissions: ["Manage Channels", "Manage Webhooks"]).contains("Manage Channels, Manage Webhooks"))
    }

    @Test(arguments: ["needs_owner", "weird_thing", ""])
    func aReasonPalDoesNotKnowNeverShowsAsAnError(code: String) {
        let error = ChatSetupErrorWire(code: .installFailed, fix: .retry, reason: code)
        let status = DiscordSetupPlan.failure(error, server: studio, invite: nil)
        #expect(status.title == "Discord stopped the setup")
        #expect(status.reason == "Discord did not finish the setup. Retry in a moment.")
        #expect(status.actionTitle == "Retry")
    }

    private func waitingForTheOwner(_ fake: FakeDiscord) async -> DiscordSetupModel {
        let wizard = model(fake)
        await wizard.load()
        await wizard.flow.performPrimary()
        return wizard
    }

    @Test func aSetupThatNeedsTheOwnerAsksForTheDiscordUserIdInPlainWords() async throws {
        let wizard = await waitingForTheOwner(FakeDiscord(app: true, lists: [[studio]], installResult: .success(.needsOwner)))
        let step = wizard.flow.engine.current
        #expect(step.id == DiscordSetupPlan.ownerID)
        #expect(step.screenTitle == "Your Discord user id")
        #expect(step.body.contains("Developer Mode") && step.body.contains("Copy User ID"))
        #expect(step.primaryTitle == "Continue")
        #expect(step.fields.map(\.id) == ["owner_member_id"])
        #expect(step.fields.map(\.label) == ["Your Discord user id"])
        #expect(wizard.flow.engine.failure == nil && wizard.flow.engine.phase == .ready)
        #expect(!wizard.flow.engine.canGoBack && !wizard.flow.engine.isPrimaryEnabled)
    }

    @Test(arguments: [
        "abc", "1234567890123456", "123456789012345678901", "12345678 9012345678", "1234567890123456a8",
        "<@123456789012345678>", "１２３４５６７８９０１２３４５６７８",
    ])
    func anIdThatIsNotSeventeenToTwentyDigitsIsRefusedInline(text: String) async throws {
        let wizard = await waitingForTheOwner(FakeDiscord(app: true, lists: [[studio]], installResult: .success(.needsOwner)))
        wizard.flow.setValue(text, for: DiscordSetupPlan.ownerField)
        #expect(!wizard.flow.engine.isPrimaryEnabled)
        let shape = wizard.flow.engine.shape(of: DiscordSetupPlan.ownerField)
        #expect(shape.message(label: "Your Discord user id") == "That is not a user id. It has 17 to 20 digits. Copy it again.")
    }

    @Test(arguments: ["12345678901234567", "123456789012345678", "12345678901234567890", "  123456789012345678\n"])
    func anIdOfSeventeenToTwentyDigitsEnablesContinue(text: String) async throws {
        let wizard = await waitingForTheOwner(FakeDiscord(app: true, lists: [[studio]], installResult: .success(.needsOwner)))
        wizard.flow.setValue(text, for: DiscordSetupPlan.ownerField)
        #expect(wizard.flow.engine.isPrimaryEnabled)
        #expect(wizard.flow.engine.shape(of: DiscordSetupPlan.ownerField) == .valid)
    }

    @Test func continueSendsTheTrimmedIdForThePickedServerAndFinishes() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio, garage]], installResult: .success(.needsOwner))
        let wizard = model(fake)
        await wizard.load()
        wizard.flow.setSwitch("guild.333", true)
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.ownerID)
        wizard.flow.setValue(" 123456789012345678 ", for: DiscordSetupPlan.ownerField)
        await wizard.flow.performPrimary()
        #expect(await fake.confirmedOwners == [["123456789012345678", "333"]])
        #expect(wizard.flow.engine.isFinished && wizard.installed == wizardInstalled)
    }

    @Test func aFailedConfirmShowsItsReasonAndRetrySendsTheIdAgain() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio]], installResult: .success(.needsOwner))
        await fake.setOwner(.failure(missingWebhooks()))
        let wizard = await waitingForTheOwner(fake)
        wizard.flow.setValue("123456789012345678", for: DiscordSetupPlan.ownerField)
        await wizard.flow.performPrimary()
        let failure = try #require(wizard.flow.engine.failure)
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.ownerID)
        await fake.setOwner(.success(.installed(wizardInstalled)))
        await wizard.flow.recover(from: failure)
        #expect(await fake.confirmedOwners.count == 2)
        #expect(wizard.flow.engine.isFinished)
    }

    @Test func aGatewayThatStillWaitsForTheOwnerKeepsTheField() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio]], installResult: .success(.needsOwner))
        await fake.setOwner(.success(.needsOwner))
        let wizard = await waitingForTheOwner(fake)
        wizard.flow.setValue("123456789012345678", for: DiscordSetupPlan.ownerField)
        await wizard.flow.performPrimary()
        #expect(wizard.flow.engine.current.id == DiscordSetupPlan.ownerID)
        #expect(wizard.flow.engine.failure == nil && wizard.flow.engine.phase == .ready)
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
            func install(in guild: DiscordGuild) async throws -> DiscordInstallOutcome { .installed(wizardInstalled) }
            func confirmOwner(_ userID: String, in guild: DiscordGuild) async throws -> DiscordInstallOutcome { .needsOwner }
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

extension DiscordSetupWizardTests {
    @Test func aSilentGatewayEndsTheFirstLoadInAPlainError() async {
        let fake = FakeDiscord(app: true, lists: [[studio]])
        await fake.silence(["appExists"])
        let wizard = model(fake)
        await wizard.load()
        #expect(wizard.stage == .status(.tookTooLong))
        await fake.silence([])
        await wizard.load()
        #expect(wizard.stage == .flow)
    }

    @Test func aSilentInstallFailsInPlainWordsAndRetryFinishes() async throws {
        let fake = FakeDiscord(app: true, lists: [[studio]])
        await fake.silence(["install"])
        let wizard = model(fake)
        await wizard.load()
        await wizard.flow.performPrimary()
        let failure = try #require(wizard.flow.engine.failure)
        #expect(failure == .tookTooLong)
        #expect(!wizard.flow.engine.isFinished)
        await fake.silence([])
        await wizard.flow.recover(from: failure)
        #expect(wizard.flow.engine.isFinished)
    }
}
