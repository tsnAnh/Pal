import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

let discordFlowToken = "MTAxMDEwMTAxMDEwMTAxMDEw.Gfake0.fake-token-do-not-use-000000"
let discordInviteRead = "https://discord.com/oauth2/authorize?client_id=101010&scope=bot&permissions=66560"
let discordInvitePost = "https://discord.com/oauth2/authorize?client_id=101010&scope=bot&permissions=68672"

func discordFlowRow(withInvite: Bool = true) -> JSONValue {
    let links: [JSONValue] = withInvite
        ? [
            ["label": "Invite the bot to read", "url": .string(discordInviteRead)],
            ["label": "Invite the bot to read and post", "url": .string(discordInvitePost)],
        ]
        : []
    let steps: [JSONValue] = [
        ["id": "invite", "kind": "open_page", "title": "Add the bot", "links": .array(links)],
    ]
    return [
        "slug": "discord", "name": "Discord", "method": "bot_token_stdio", "status": "not_connected",
        "setup_guide": ["steps": .array(steps)],
    ]
}

let discordNoGuilds: JSONValue = ["guilds": [], "allowed": [], "read_only": true]

let discordGuilds: JSONValue = [
    "guilds": [["id": "111", "name": "Team"], ["id": "222", "name": "Friends"]], "allowed": ["222"], "read_only": true,
]

func discordFlowEntry() -> PalCatalogEntry {
    catalogEntry("discord", "Discord", "Communication", method: .botTokenStdio, url: nil)
}

func discordFlowRunner(_ rpc: CustomRPC, attempts: Int = 3) -> DiscordFlowRunner {
    DiscordFlowRunner(
        service: customService(rpc), entry: discordFlowEntry(), timing: DiscordFlowRunner.Timing(interval: .milliseconds(5), attempts: attempts)
    )
}

@Suite("Discord flow steps")
struct DiscordFlowStepTests {
    @Test func theTokenMustBeThreePartsJoinedByDotsBeforeItIsSent() {
        let field = DiscordFlow.tokenField
        #expect(field.shape(of: "") == .empty)
        #expect(field.shape(of: "MTA1") == .wrongParts(3))
        #expect(field.shape(of: "MTA1.Gfake0") == .wrongParts(3))
        #expect(field.shape(of: "MTA1..tail") == .wrongParts(3))
        #expect(field.shape(of: "a.b.c.d") == .wrongParts(3))
        #expect(field.shape(of: "MTA1 .Gfake0.tail") == .hasSpaces)
        #expect(field.shape(of: discordFlowToken) == .valid)
    }

    @Test func aWrongShapeReadsAsOnePlainSentence() {
        let message = SetupFieldShape.wrongParts(3).message(label: "Bot token")
        #expect(message == "That is not a bot token. A bot token is three parts joined by dots. Copy it again.")
    }

    @Test func theChecklistHasTheFiveStepsOfTheMockupAndAnEndScreen() throws {
        let engine = try #require(DiscordFlow.engine(resume: nil))
        #expect(engine.checklist.map(\.title) == [
            "Create the bot", "Paste the token", "Turn on intents", "Invite to servers", "Choose what it may do",
        ])
        #expect(engine.checklist.allSatisfy { !$0.isAutomatic })
        #expect(engine.positionLabel == "Step 1 of 5")
        #expect(engine.current.id == DiscordFlow.StepID.bot)
        #expect(engine.steps.last?.isSuccess == true)
    }

    @Test(arguments: [
        ("bot", "bot"), ("token", "token"), ("invite", "intents"), ("servers", "access"), ("access", "access"), ("unknown", "bot"),
    ])
    func theGatewaySavedStepMapsOntoTheMatchingStep(saved: String, expected: String) throws {
        let engine = try #require(DiscordFlow.engine(resume: SetupProgress(stepID: saved, saved: ["token"])))
        #expect(engine.current.id == expected)
    }

    @Test func theTokenIsAnEarlierStepThanTheOneAResumedFlowStartsOn() throws {
        let engine = try #require(DiscordFlow.engine(resume: SetupProgress(stepID: "invite", saved: ["token"])))
        #expect(engine.checklist.map(\.state) == [.done, .done, .current, .upcoming, .upcoming])
        #expect(engine.progress.saved == ["token"])
    }

    @Test func theIntentStepNeedsTheBoxTickedAndCanBeUnticked() throws {
        var engine = try #require(DiscordFlow.engine(resume: SetupProgress(stepID: "invite", saved: ["token"])))
        #expect(!engine.isPrimaryEnabled)
        let blocked = engine.advance()
        #expect(!blocked)
        engine.setConfirmed("ghost", true)
        #expect(!engine.isConfirmed("ghost") && !engine.isPrimaryEnabled)
        engine.setConfirmed("message_content", true)
        #expect(engine.isPrimaryEnabled)
        engine.setConfirmed("message_content", false)
        #expect(!engine.isPrimaryEnabled)
        engine.setConfirmed("message_content", true)
        let moved = engine.advance()
        #expect(moved)
        #expect(engine.current.id == DiscordFlow.StepID.invite)
    }

    @Test func theServerSwitchesNeedOneServerOnAndKeepTheirDefaults() throws {
        var engine = try #require(DiscordFlow.engine(resume: SetupProgress(stepID: "access", saved: ["token"])))
        let groups = [
            SetupSwitchGroup(id: "access", switches: [SetupSwitch(id: "read_only", title: "Read only", isOn: true)]),
            SetupSwitchGroup(
                id: "servers", header: "Servers it may use",
                switches: [SetupSwitch(id: "guild.111", title: "Team"), SetupSwitch(id: "guild.222", title: "Friends")], needsOneOn: true
            ),
        ]
        engine.replaceKind(of: "access", with: .switches(groups: groups))
        #expect(engine.isOn("read_only") && !engine.isOn("guild.111"))
        #expect(!engine.isPrimaryEnabled)
        engine.setSwitch("guild.222", true)
        #expect(engine.isPrimaryEnabled)
        engine.setSwitch("read_only", false)
        #expect(engine.workValues["read_only"] == "0" && engine.workValues["guild.222"] == "1" && engine.workValues["guild.111"] == "0")
        engine.setSwitch("guild.222", false)
        #expect(!engine.isPrimaryEnabled)
        engine.setSwitch("elsewhere", true)
        #expect(!engine.isOn("elsewhere"))
    }

    @Test func aStepCannotBeTurnedIntoTheEndScreenOrChangeTheRowCount() throws {
        var engine = try #require(DiscordFlow.engine(resume: nil))
        let toEnd = engine.replaceKind(of: "bot", with: .success(title: "x", body: ""))
        let missing = engine.replaceKind(of: "missing", with: .automatic)
        #expect(!toEnd && !missing)
        #expect(engine.stepCount == 5 && !engine.steps[0].isSuccess)
    }
}

@Suite("Discord flow runner")
struct DiscordFlowRunnerTests {
    private func tokenStep() throws -> FlowStep {
        try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.token })
    }

    @Test func aTokenDiscordRefusesIsNeverSavedAndReadsAsAPlainRefusal() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": false, "reason": "invalid_token", "message": "no"] },
        ])
        let flow = discordFlowRunner(rpc)
        let step = try tokenStep()
        do {
            try await flow.run(step, values: ["token": discordFlowToken])
            Issue.record("expected a refusal")
        } catch {
            let status = flow.classify(error)
            #expect(status.kind == .vendorRefusedValue)
            #expect(status.title == "Discord did not accept that token")
            #expect(status.reason == "Copy it again from the Bot page. A token is three parts joined by dots.")
        }
        #expect(rpc.params("connectors.discord.token").isEmpty)
        #expect(rpc.params("vault.remove").compactMap { $0["id"]?.stringValue } == ["item-1"])
    }

    @Test func discordBeingUnreachableIsNotBlamedOnTheToken() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": false, "reason": "check_unavailable"] },
        ])
        let flow = discordFlowRunner(rpc)
        do {
            try await flow.run(try tokenStep(), values: ["token": discordFlowToken])
            Issue.record("expected a failure")
        } catch {
            let status = flow.classify(error)
            #expect(status.kind != .vendorRefusedValue)
            #expect(status.title == "Pal couldn't reach Discord")
            #expect(status.code == "check_unavailable")
        }
    }

    @Test func aGoodTokenReachesTheGatewayOnlyAsAVaultItem() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": true, "account": "palbot"] },
            "connectors.discord.token": { _ in ["bot_name": "palbot", "application_id": "101010"] },
        ])
        try await discordFlowRunner(rpc).run(try tokenStep(), values: ["token": "  \(discordFlowToken)\n"])
        #expect(rpc.params("connectors.discord.token").first?["item"]?.stringValue == "item-1")
        let wire = try #require(String(bytes: try JSONEncoder().encode(rpc.params("connectors.discord.token")), encoding: .utf8))
        #expect(!wire.contains(discordFlowToken))
        let stored = rpc.params("vault.add").first?["secret"]?["api_key"]?.stringValue
        #expect(stored == discordFlowToken)
    }

    @Test func theInviteStepWaitsUntilTheBotIsInAServerThenAdvances() async throws {
        let polls = CallCounter()
        let rpc = CustomRPC([
            "connectors.discord.guilds": { _ in
                polls.next() < 3 ? discordNoGuilds : discordGuilds
            },
        ])
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.invite })
        try await discordFlowRunner(rpc, attempts: 5).run(step, values: [:])
        #expect(rpc.params("connectors.discord.guilds").count == 3)
    }

    @Test func aBotThatNeverJoinsEndsInOnePlainSentenceWithCheckAgain() async throws {
        let rpc = CustomRPC(["connectors.discord.guilds": { _ in discordNoGuilds }])
        let flow = discordFlowRunner(rpc, attempts: 2)
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.invite })
        do {
            try await flow.run(step, values: [:])
            Issue.record("expected the wait to end")
        } catch {
            let status = flow.classify(error)
            #expect(status.title == "The bot isn't in a server yet")
            #expect(status.actionTitle == "Check again")
            #expect(status.code == "bot_not_in_server")
        }
        #expect(rpc.params("connectors.discord.guilds").count == 2)
    }

    @Test func theInviteLinksComeFromTheGatewayAndTheFirstOneIsTheOneThatOpens() async throws {
        let rpc = CustomRPC(["connectors.catalog": { _ in ["connectors": [discordFlowRow()]] }])
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.invite })
        let kind = try #require(try await discordFlowRunner(rpc).prepare(step))
        guard case .openAndCheck(let open) = kind else { return Issue.record("expected an invite step") }
        #expect(open.link.url.absoluteString == discordInviteRead && open.link.label == "Open invite link")
        #expect(open.copies.map(\.value) == [discordInviteRead, discordInvitePost])
    }

    @Test func noInviteLinkMeansThePalNeedsAnUpdate() async throws {
        let rpc = CustomRPC(["connectors.catalog": { _ in ["connectors": [discordFlowRow(withInvite: false)]] }])
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.invite })
        let flow = discordFlowRunner(rpc)
        do {
            _ = try await flow.prepare(step)
            Issue.record("expected a failure")
        } catch {
            #expect(flow.classify(error).kind == .gatewayOutdated)
        }
    }

    @Test func theServerListBecomesSwitchesWithReadOnlyAskingBeforeItTurnsOff() async throws {
        let rpc = CustomRPC(["connectors.discord.guilds": { _ in discordGuilds }])
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.access })
        let kind = try #require(try await discordFlowRunner(rpc).prepare(step))
        guard case .switches(let groups) = kind else { return Issue.record("expected switches") }
        let readOnly = try #require(groups.first?.switches.first)
        #expect(readOnly.isOn && readOnly.confirmTurningOff?.title == "Let the bot post?" && readOnly.confirmTurningOff?.confirmTitle == "Allow posting")
        let servers = try #require(groups.last)
        #expect(servers.needsOneOn && servers.switches.map(\.id) == ["guild.111", "guild.222"])
        #expect(servers.switches.map(\.isOn) == [false, true])
    }

    @Test func savingSendsTheSwitchedOnServersAndTheAccessChoice() async throws {
        let rpc = CustomRPC(["connectors.discord.save": { _ in ["tools": 11, "read_only": false, "guild_ids": ["111"]] }])
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.access })
        try await discordFlowRunner(rpc).run(step, values: ["read_only": "0", "guild.111": "1", "guild.222": "0"])
        let sent = try #require(rpc.params("connectors.discord.save").first)
        #expect(sent["guild_ids"]?.arrayValue?.compactMap(\.stringValue) == ["111"] && sent["read_only"]?.boolValue == false)
    }

    struct MappingCase: Sendable {
        let error: any Error
        let kind: SetupStatusClass
    }

    @Test(arguments: [
        MappingCase(error: GatewayTransportError.timedOut, kind: .offline),
        MappingCase(error: ConnectAppsError.oauthClient(.unreachable), kind: .offline),
        MappingCase(error: ConnectAppsError.oauthClient(.notOwner), kind: .forbidden),
        MappingCase(
            error: GatewayTransportError.rpc(RPCError(code: 4030, message: "x", data: ["reason": "not_owner"])), kind: .forbidden
        ),
        MappingCase(
            error: GatewayTransportError.rpc(RPCError(code: 5034, message: "x", data: ["reason": "connect_failed"])), kind: .internalFault
        ),
        MappingCase(error: ConnectAppsError.failed, kind: .internalFault),
    ])
    func errorsMapToOneOfTheSharedStatuses(_ test: MappingCase) {
        #expect(SetupStatus(error: test.error, subject: "Discord").kind == test.kind)
    }

    @Test func aGatewayFaultKeepsItsMethodAndCodeForDetails() {
        let rpc = RPCError(code: 5034, message: "x", data: ["reason": "connect_failed"])
        let status = SetupStatus(error: ConnectAppsError.faulted(GatewayFault(rpc, method: "connectors.discord.save")), subject: "Discord")
        #expect(status.code == "connect_failed" && status.method == "connectors.discord.save" && status.trace != nil)
    }
}
