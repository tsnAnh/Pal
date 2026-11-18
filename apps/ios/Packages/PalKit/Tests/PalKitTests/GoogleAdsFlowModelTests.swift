import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

@Suite("Google Ads flow model")
@MainActor
struct GoogleAdsFlowModelTests {
    private let overview = "https://console.cloud.google.com/apis/api/googleads.googleapis.com/overview"

    private func model(_ rpc: CustomRPC, status: GoogleAdsStatus? = nil) throws -> StepFlowModel {
        let runner = GoogleAdsFlowRunner(service: customService(rpc, system: BlockingBrowser()))
        let engine = try #require(GoogleAdsFlow.engine(status: status))
        let flow = StepFlowModel(
            engine: engine, runner: { step, values in try await runner.run(step, values: values) }, classify: { runner.classify($0) }
        )
        flow.recovery = { [weak flow] failure in
            guard let flow else { return }
            await GoogleAdsFlow.recover(failure, in: flow)
        }
        return flow
    }

    private func calls(_ rpc: CustomRPC, _ prefix: String) -> [String] {
        rpc.methods().filter { $0.hasPrefix(prefix) }
    }

    @Test func theWholeFlowRunsFromTheFirstPageToTheEndScreenWithAManagerAccount() async throws {
        let gateway = AdsGateway(signedIn: false)
        let rpc = gateway.rpc()
        let flow = try model(rpc)
        var opened: [String] = []
        flow.openPage = { opened.append($0.absoluteString) }
        await flow.start()

        for expected in ["api", "explorer", "consent"] {
            #expect(flow.engine.current.id == expected)
            await flow.performPrimary()
        }
        #expect(opened == [
            "https://console.cloud.google.com/apis/library/googleads.googleapis.com", overview,
            "https://console.cloud.google.com/apis/credentials/consent",
        ])
        #expect(flow.engine.current.id == "signin")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "manager")
        #expect(calls(rpc, "connectors.google_ads").isEmpty)

        flow.setValue("123-456-7890", for: "manager")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "check")
        #expect(rpc.params("connectors.google_ads.save").first?["login_customer_id"]?.stringValue == "1234567890")

        await flow.performPrimary()
        #expect(flow.engine.isFinished)
        #expect(calls(rpc, "connectors.google_ads") == [
            "connectors.google_ads.save", "connectors.google_ads.status", "connectors.google_ads.verify",
        ])
        #expect(gateway.manager == "1234567890")
    }

    @Test func skippingTheManagerAccountSavesWithoutOneAndStillVerifies() async throws {
        let gateway = AdsGateway(signedIn: true, configured: false)
        let rpc = gateway.rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: false))
        await flow.start()
        #expect(flow.engine.current.id == "manager")
        await flow.skip()
        #expect(flow.engine.current.id == "check" && rpc.methods().isEmpty)
        await flow.performPrimary()
        #expect(flow.engine.isFinished)
        #expect(rpc.params("connectors.google_ads.save").map { $0["login_customer_id"] } == [JSONValue.null])
        #expect(calls(rpc, "connectors.google_ads").last == "connectors.google_ads.verify")
    }

    @Test func aSavedServerIsOnlyVerifiedNotSavedAgain() async throws {
        let rpc = AdsGateway(signedIn: true, configured: true).rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: true, loginCustomerID: "1234567890"))
        await flow.start()
        #expect(flow.engine.current.id == "check")
        await flow.performPrimary()
        #expect(flow.engine.isFinished)
        #expect(calls(rpc, "connectors.google_ads") == ["connectors.google_ads.status", "connectors.google_ads.verify"])
    }

    @Test func lettersInTheManagerIdAreRefusedOnTheFieldBeforeAnythingIsSent() async throws {
        let rpc = AdsGateway().rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: false))
        await flow.start()
        flow.setValue("12ab34", for: "manager")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "manager" && flow.engine.failure?.kind == .vendorRefusedValue)
        #expect(flow.engine.current.inlineRefusal)
        #expect(flow.engine.failure?.title == "That manager account ID does not look right")
        #expect(rpc.methods().isEmpty)
        flow.setValue("1234", for: "manager")
        #expect(flow.engine.failure == nil && flow.engine.isPrimaryEnabled)
    }

    @Test func aGatewayThatRefusesTheIdShowsTheSameStatusOnTheField() async throws {
        let rpc = AdsGateway().rpc(save: rpcFailure(4000, reason: "INVALID_PARAMS"))
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: false))
        await flow.start()
        flow.setValue("1234", for: "manager")
        await flow.performPrimary()
        #expect(flow.engine.failure?.kind == .vendorRefusedValue && flow.engine.current.id == "manager")
    }

    @Test func aHandshakeThatFailsKeepsTheStepAndRetryRunsItAgain() async throws {
        let attempts = CallCounter()
        let rpc = AdsGateway().rpc(save: { params in
            if attempts.next() == 1 { throw GatewayTransportError.rpc(RPCError(code: 5034, message: "x", data: ["reason": "CONNECT_FAILED"])) }
            return ["tools": 6, "login_customer_id": params["login_customer_id"] ?? .null]
        })
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: false))
        await flow.start()
        flow.setValue("1234", for: "manager")
        await flow.performPrimary()
        #expect(flow.engine.current.id == "manager" && flow.engine.failure?.title == "Pal could not start Google Ads")
        await flow.retryAfterFailure()
        #expect(flow.engine.current.id == "check" && flow.engine.failure == nil)
    }

    @Test func aNonOwnerGetsTheForbiddenStatus() async throws {
        let rpc = AdsGateway().rpc(save: rpcFailure(4030, reason: "NOT_OWNER"))
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: false))
        await flow.start()
        flow.setValue("1234", for: "manager")
        await flow.performPrimary()
        #expect(flow.engine.failure?.kind == .forbidden)
    }

    @Test func explorerAccessNeededShowsItsStatusAndReopensThePageThenChecksAgain() async throws {
        let gateway = AdsGateway(signedIn: true, configured: true, checks: ["explorer_access_needed", "ready"])
        let rpc = gateway.rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: true))
        var opened: [String] = []
        flow.openPage = { opened.append($0.absoluteString) }
        await flow.start()
        await flow.performPrimary()
        let failure = try #require(flow.engine.failure)
        #expect(failure.kind == .explorerAccessNeeded && failure.title == "Apply for Explorer access")
        #expect(flow.engine.current.id == "check")

        await flow.recover(from: failure)
        #expect(opened == [overview] && flow.engine.failure == nil && flow.engine.current.id == "check")
        #expect(flow.engine.isPrimaryEnabled)

        await flow.performPrimary()
        #expect(flow.engine.isFinished)
        #expect(calls(rpc, "connectors.google_ads.save").isEmpty)
    }

    @Test func aRevokedSignInSendsReconnectBackToTheSignInStep() async throws {
        let rpc = AdsGateway(signedIn: true, configured: true, checks: ["needs_reauth"]).rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: true))
        await flow.start()
        await flow.performPrimary()
        let failure = try #require(flow.engine.failure)
        #expect(failure.kind == .needsReauth && failure.actionTitle == "Reconnect")
        await flow.recover(from: failure)
        #expect(flow.engine.current.id == "signin" && flow.engine.failure == nil)
    }

    @Test func aSignInThatGoogleLostIsCaughtBeforeAnythingIsVerified() async throws {
        let rpc = AdsGateway(signedIn: false, configured: true).rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: true))
        await flow.start()
        await flow.performPrimary()
        #expect(flow.engine.failure?.kind == .needsReauth)
        #expect(calls(rpc, "connectors.google_ads") == ["connectors.google_ads.status"])
    }

    @Test func aGoogleThatDoesNotAnswerShowsUnreachableAndRetryChecksAgain() async throws {
        let rpc = AdsGateway(signedIn: true, configured: true, checks: ["unreachable", "ready"]).rpc()
        let flow = try model(rpc, status: GoogleAdsStatus(state: .signedIn, configured: true))
        await flow.start()
        await flow.performPrimary()
        #expect(flow.engine.failure?.kind == .offline && flow.engine.failure?.title == "Pal could not reach Google Ads")
        await flow.retryAfterFailure()
        #expect(flow.engine.isFinished)
    }

    @Test func aMissingGoogleClientFailsTheSignInWithTheWorkspaceHint() async throws {
        let rpc = AdsGateway(signedIn: false).rpc(extra: ["connectors.oauth_client.connect": rpcFailure(4090, reason: "NEEDS_SETUP")])
        let flow = try model(rpc, status: GoogleAdsStatus(state: .needsReconnect, configured: false))
        await flow.start()
        #expect(flow.engine.current.id == "signin")
        await flow.performPrimary()
        #expect(flow.engine.failure?.title == "Set up Google Workspace first")
    }
}
