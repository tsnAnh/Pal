import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

@Suite("Discord flow model")
@MainActor
struct DiscordFlowModelTests {
    private func model(_ rpc: CustomRPC, resume: SetupProgress? = nil) throws -> StepFlowModel {
        let flow = discordFlowRunner(rpc)
        let engine = try #require(DiscordFlow.engine(resume: resume))
        return StepFlowModel(
            engine: engine, runner: { step, values in try await flow.run(step, values: values) },
            classify: { flow.classify($0) }, prepare: { try await flow.prepare($0) }
        )
    }

    private func gateway(guilds: @escaping CustomRPC.Reply = { _ in discordGuilds }) -> CustomRPC {
        CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": true, "account": "palbot"] },
            "connectors.discord.token": { _ in ["bot_name": "palbot", "application_id": "101010"] },
            "connectors.catalog": { _ in ["connectors": [discordFlowRow()]] },
            "connectors.discord.guilds": guilds,
            "connectors.discord.save": { _ in ["tools": 11, "read_only": true, "guild_ids": ["222"]] },
        ])
    }

    @Test func theWholeFlowRunsFromTheBotToTheEndScreenAndOpensBothPages() async throws {
        let rpc = gateway()
        let flow = try model(rpc)
        var opened: [String] = []
        flow.openPage = { opened.append($0.absoluteString) }
        await flow.start()

        await flow.performPrimary()
        #expect(flow.engine.current.id == "token")
        flow.setValue(discordFlowToken, for: "token")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "intents")

        flow.setConfirmed("message_content", true)
        await flow.performPrimary()
        #expect(flow.engine.current.id == "invite")
        #expect(flow.engine.phase == .ready)
        await flow.performPrimary()
        #expect(opened == ["https://discord.com/developers/applications", discordInviteRead])
        #expect(flow.engine.current.id == "access")
        #expect(flow.engine.isOn("guild.222") && flow.engine.isOn("read_only"))

        await flow.performPrimary()
        #expect(flow.engine.isFinished)
        let sent = try #require(rpc.params("connectors.discord.save").first)
        #expect(sent["guild_ids"]?.arrayValue?.compactMap(\.stringValue) == ["222"] && sent["read_only"]?.boolValue == true)
    }

    @Test func aRefusedTokenStaysOnTheStepAndAnEditClearsTheRefusal() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": false, "reason": "invalid_token"] },
        ])
        let flow = try model(rpc, resume: SetupProgress(stepID: "token"))
        await flow.start()
        flow.setValue(discordFlowToken, for: "token")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "token" && flow.engine.failure?.kind == .vendorRefusedValue)
        #expect(flow.engine.current.inlineRefusal)
        flow.setValue(discordFlowToken + "x", for: "token")
        #expect(flow.engine.failure == nil && flow.engine.isPrimaryEnabled)
    }

    @Test func checkAgainWaitsForTheBotWithoutOpeningTheLinkAgain() async throws {
        let polls = CallCounter()
        let rpc = gateway(guilds: { _ in polls.next() <= 2 ? discordNoGuilds : discordGuilds })
        let flow = try model(rpc, resume: SetupProgress(stepID: "invite", saved: ["token"]))
        var opened = 0
        flow.openPage = { _ in opened += 1 }
        await flow.start()
        #expect(flow.engine.current.id == "intents")
        flow.setConfirmed("message_content", true)
        await flow.performPrimary()
        #expect(flow.engine.current.id == "invite")
        await flow.recheck()
        #expect(opened == 0)
        #expect(flow.engine.current.id == "access")
    }

    @Test func aBotThatIsNotThereYetShowsCheckAgainAndRetryDoesNotReopenTheLink() async throws {
        let polls = CallCounter()
        let rpc = gateway(guilds: { _ in polls.next() <= 3 ? discordNoGuilds : discordGuilds })
        let flow = try model(rpc, resume: SetupProgress(stepID: "token", saved: ["token"]))
        var opened = 0
        flow.openPage = { _ in opened += 1 }
        await flow.start()
        flow.setValue(discordFlowToken, for: "token")
        await flow.performPrimary()
        flow.setConfirmed("message_content", true)
        await flow.performPrimary()
        await flow.performPrimary()
        #expect(flow.engine.current.id == "invite" && flow.engine.failure?.title == "The bot isn't in a server yet")
        #expect(opened == 1)
        await flow.retryAfterFailure()
        #expect(opened == 1 && flow.engine.current.id == "access")
    }

    @Test func aFailedServerListShowsOneStatusAndRetryLoadsItAgain() async throws {
        let attempts = CallCounter()
        let rpc = gateway(guilds: { _ in
            if attempts.next() == 1 { throw GatewayTransportError.timedOut }
            return discordGuilds
        })
        let flow = try model(rpc, resume: SetupProgress(stepID: "access", saved: ["token"]))
        await flow.start()
        #expect(flow.engine.current.id == "access" && flow.engine.failure?.kind == .offline)
        await flow.retryAfterFailure()
        #expect(flow.engine.failure == nil && flow.engine.isOn("guild.222"))
        #expect(flow.engine.isPrimaryEnabled)
    }

    @Test func goingBackFromTheSwitchesLoadsTheInviteStepAgain() async throws {
        let rpc = gateway()
        let flow = try model(rpc, resume: SetupProgress(stepID: "access", saved: ["token"]))
        await flow.start()
        await flow.back()
        #expect(flow.engine.current.id == "invite" && flow.engine.phase == .ready)
        #expect(rpc.params("connectors.catalog").count == 1)
    }
}
