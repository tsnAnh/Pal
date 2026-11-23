import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

private let invalidTokenText =
    "Discord didn't accept the saved bot token. Open the Discord developer portal, reset the token and paste it again."

private struct Refusal: Sendable {
    var code: Int
    var reason: String?
    var message: String
    var title: String
    var action: String
}

private let refusals: [Refusal] = [
    Refusal(code: 4000, reason: "INVALID_TOKEN", message: invalidTokenText, title: "Discord did not accept the bot token",
            action: "Back to the token step"),
    Refusal(code: 4090, reason: "NEEDS_SETUP", message: "Paste your Discord bot token first.", title: "Pal needs your bot token first",
            action: "Back to the token step"),
    Refusal(code: 5034, reason: "CHECK_UNAVAILABLE", message: "Discord asked Pal to wait 42 seconds. Try again then.",
            title: "Pal could not check with Discord", action: "Try again"),
    Refusal(code: 5034, reason: "CHECK_UNAVAILABLE", message: "The Pal gateway could not reach Discord. Check its internet connection and try again.",
            title: "Pal could not check with Discord", action: "Try again"),
    Refusal(code: 4030, reason: "NOT_OWNER", message: "Only the owner can set up this app.", title: "Only the owner can do this", action: "Close"),
    Refusal(code: 5000, reason: nil, message: "Something broke on your Pal.", title: "Pal could not finish", action: "Try again"),
]

@Suite("Discord refusals keep the gateway's reason")
@MainActor
struct DiscordRefusalTests {
    private func gateway(guilds: @escaping CustomRPC.Reply) -> CustomRPC {
        CustomRPC([
            "connectors.catalog": { _ in ["connectors": [discordFlowRow()]] },
            "connectors.discord.guilds": guilds,
        ])
    }

    private func lastStep(_ rpc: CustomRPC) throws -> StepFlowModel {
        let flow = discordFlowRunner(rpc)
        let engine = try #require(DiscordFlow.engine(resume: SetupProgress(stepID: "access", saved: ["token"])))
        return StepFlowModel(
            engine: engine, runner: { step, values in try await flow.run(step, values: values) },
            classify: { flow.classify($0) }, prepare: { try await flow.prepare($0) }
        )
    }

    @Test(arguments: refusals) fileprivate func theLastStepShowsTheGatewaysOwnReasonAndTheNextStep(_ refusal: Refusal) async throws {
        let flow = try lastStep(gateway(guilds: rpcFailure(refusal.code, reason: refusal.reason, message: refusal.message)))
        await flow.start()

        let status = try #require(flow.engine.failure)
        #expect(status.title == refusal.title && status.actionTitle == refusal.action)
        #expect(status.reason == refusal.message || status.kind == .forbidden)
        #expect(status.code == (refusal.reason ?? "internal"))
        #expect(status.method == "connectors.discord.guilds")
        #expect(status.trace?.isEmpty == false)
        #expect(status.reason != "Couldn't start the sign-in. Try again.")
        #expect(status.detailsText(appBuild: "1").contains("connectors.discord.guilds"))
    }

    @Test(arguments: refusals) fileprivate func theDiscordCallsNeverTurnIntoTheGenericSignInFailure(_ refusal: Refusal) async throws {
        let service = customService(gateway(guilds: rpcFailure(refusal.code, reason: refusal.reason, message: refusal.message)))
        do {
            _ = try await service.discordServers()
            Issue.record("expected a refusal")
        } catch let error as SetupStatusError {
            #expect(error.status.code == (refusal.reason ?? "internal"))
        } catch {
            Issue.record("the gateway's refusal was replaced by \(error)")
        }
    }

    @Test func theGenericClassifierStillCollapsesTheseReasonsSoDiscordMustNotUseIt() {
        #expect(OAuthClientFailure.classify(reason: "CHECK_UNAVAILABLE", code: 5034) == .connectFailed)
        #expect(OAuthClientFailure.classify(reason: "INVALID_TOKEN", code: 4000) == .connectFailed)
    }

    @Test func aRefusedTokenAfterTheCheckStaysOnTheFieldWithItsOwnCopy() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "discord", "ok": true, "account": "palbot"] },
            "connectors.discord.token": rpcFailure(4000, reason: "INVALID_TOKEN", message: invalidTokenText),
        ])
        let flow = discordFlowRunner(rpc)
        let step = try #require(DiscordFlow.steps().first { $0.id == DiscordFlow.StepID.token })
        do {
            try await flow.run(step, values: ["token": discordFlowToken])
            Issue.record("expected a refusal")
        } catch {
            let status = flow.classify(error)
            #expect(status.kind == .vendorRefusedValue && status.code == "INVALID_TOKEN")
            #expect(status.actionTitle == "Edit token")
        }
        #expect(rpc.params("vault.remove").compactMap { $0["id"]?.stringValue } == ["item-1"])
    }

    @Test func aRefusedTokenOnTheLastStepSendsYouBackToTheTokenStep() async throws {
        let rpc = gateway(guilds: rpcFailure(4000, reason: "INVALID_TOKEN", message: invalidTokenText))
        let flow = try lastStep(rpc)
        await flow.start()
        let status = try #require(flow.engine.failure)

        await DiscordFlow.recover(status, in: flow)

        #expect(flow.engine.current.id == DiscordFlow.StepID.token && flow.engine.failure == nil)
    }

    @Test func anUnreachableDiscordIsRetriedInPlace() async throws {
        let reads = CallCounter()
        let rpc = gateway(guilds: { _ in
            if reads.next() == 1 {
                throw GatewayTransportError.rpc(RPCError(code: 5034, message: "x", data: ["reason": "CHECK_UNAVAILABLE"]))
            }
            return discordGuilds
        })
        let flow = try lastStep(rpc)
        await flow.start()
        let status = try #require(flow.engine.failure)

        await DiscordFlow.recover(status, in: flow)

        #expect(flow.engine.current.id == "access" && flow.engine.failure == nil && flow.engine.isOn("guild.222"))
    }
}
