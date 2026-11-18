import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

private func t3Gateway(
    add: CustomRPC.Reply? = nil, update: CustomRPC.Reply? = nil, test: @escaping CustomRPC.Reply
) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": add ?? { _ in ["ok": true] },
        "mcp.servers.update": update ?? { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.test": test,
    ])
}

private func testReply(reason: String) -> CustomRPC.Reply {
    { _ in ["ok": false, "reason": .string(reason), "oauth_needed": false, "oauth_tokens_present": false] }
}

private func thrownError(_ work: () async throws -> Void) async -> (any Error)? {
    do { try await work(); return nil } catch { return error }
}

@Suite("T3 Code flow")
struct T3CodeFlowTests {
    @Test func theWizardHasTheFourStepsInOrder() {
        let steps = T3CodeFlow.steps()
        #expect(steps.map(\.id) == ["network", "address", "signin", "done"])
        #expect(steps.map(\.title) == ["Turn on network access in T3 Code", "Paste the address and port", "Sign in to T3 Code", "Connected"])
        #expect(steps[2].primaryTitle == "Sign in with T3 Code")
        #expect(steps[1].primaryTitle == "Check address")
    }

    @Test func theFirstStepOffersWhereAndTheCommandToCopy() throws {
        let step = T3CodeFlow.steps()[0]
        guard case .copyCard(let copies) = step.kind else {
            Issue.record("the first step is a copy card")
            return
        }
        #expect(copies.map(\.label) == ["Where", "Command"])
        #expect(copies.map(\.value) == ["T3 Code, Settings, Network access", "t3 serve --host <your Mac's Tailscale address>"])
        #expect(step.body == "On your Mac, open T3 Code, go to Settings and turn on Network access. Or run the command below in a terminal.")
    }

    @Test func theAddressStepAsksForOneVisibleField() {
        let step = T3CodeFlow.steps()[1]
        #expect(step.fields == [SetupField(id: "address", label: "Address", secret: false)])
        #expect(step.body == "Use your Mac's Tailscale address and the port T3 Code shows, for example 100.64.0.5:3773.")
    }

    @Test func theSignInStepWaitsInTheBrowserAndTheLastStepSaysConnected() {
        let steps = T3CodeFlow.steps()
        #expect(steps[2].kind == .browserRoundTrip(
            waitingTitle: "Waiting for T3 Code",
            waitingBody: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done."
        ))
        #expect(steps[3].kind == .success(
            title: "T3 Code is connected",
            body: "Your bots can send coding work to T3 Code while it is reachable. You will not be asked for this again."
        ))
    }

    @Test func theEngineStartsAtTheTopOrResumesAtTheChosenStep() throws {
        #expect(try #require(T3CodeFlow.engine(resumeAt: nil)).current.id == "network")
        #expect(try #require(T3CodeFlow.engine(resumeAt: .address)).current.id == "address")
        let signIn = try #require(T3CodeFlow.engine(resumeAt: .signIn))
        #expect(signIn.current.id == "signin" && signIn.progress.flowID == "t3code" && signIn.progress.saved.isEmpty)
        #expect(signIn.stepCount == 3 && signIn.stepNumber == 3)
    }

    @Test func theAddressCannotBeCheckedUntilSomethingIsTyped() throws {
        var engine = try #require(T3CodeFlow.engine(resumeAt: .address))
        #expect(!engine.isPrimaryEnabled)
        engine.setValue("100.109.203.70:3773", for: "address")
        #expect(engine.isPrimaryEnabled)
        engine.setValue("100.109.203.70 3773", for: "address")
        #expect(!engine.isPrimaryEnabled)
    }

    @Test func eachKindOfErrorBecomesOnePlainStatusNamedAfterT3Code() {
        let timedOut = T3CodeFlow.classify(ConnectAppsError.failed)
        #expect(timedOut.kind == .offline)
        let transport = T3CodeFlow.classify(GatewayTransportError.timedOut)
        #expect(transport.kind == .offline)
        let rpc = T3CodeFlow.classify(GatewayTransportError.rpc(RPCError(code: 4030, message: "no", data: ["reason": "forbidden"])))
        #expect(rpc.kind == .forbidden)
        let fault = GatewayFault(code: 4030, reason: "forbidden", trace: TraceID.random(), method: "mcp.servers.add", source: .gateway)
        #expect(T3CodeFlow.classify(ConnectAppsError.faulted(fault)).kind == .forbidden)
        #expect(T3CodeFlow.classify(ConnectorFailure.unreachable).kind == .serverUnreachable)
        #expect(T3CodeFlow.classify(ConnectorFailure.offline).kind == .offline)
        #expect(T3CodeFlow.classify(ConnectorFailure.authRefused).kind == .needsReauth)
        #expect(T3CodeFlow.classify(ConnectorFailure.serverError).kind == .internalFault)
        #expect(T3CodeFlow.classify(ConnectAppsError.signInFailed("x")).kind == .internalFault)
        #expect(T3CodeFlow.classify(CocoaError(.fileNoSuchFile)).kind == .internalFault)
        #expect(T3CodeFlow.classify(ConnectorFailure.unreachable).title == "Pal could not reach T3 Code")
    }

    @Test func aWrongAddressAsksForTheAddressAgainInItsOwnWords() {
        let status = T3CodeFlow.classify(T3AddressError.invalidPort)
        #expect(status.kind == .vendorRefusedValue)
        #expect(status.title == "That address does not look right")
        #expect(status.reason == T3AddressError.invalidPort.message)
        #expect(status.actionTitle == "Edit address")
        #expect(status.code == "invalid_address")
    }
}

@Suite("T3 Code service")
struct T3CodeServiceTests {
    private func status(_ error: (any Error)?) -> SetupStatus? { error.map { T3CodeFlow.classify($0) } }

    @Test func aReachableServerIsAddedThenTestedAndNothingIsRemoved() async throws {
        let rpc = t3Gateway(test: okTools(["a"]))
        try await customService(rpc).checkT3Address("100.109.203.70")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test"])
        let add = try #require(rpc.params("mcp.servers.add").first)
        #expect(add["name"]?.stringValue == "t3code")
        #expect(add["config"]?["url"]?.stringValue == "http://100.109.203.70:3773/mcp")
        #expect(add["config"]?["transport"]?.stringValue == "http")
        #expect(rpc.params("mcp.servers.test").first?["name"]?.stringValue == "t3code")
    }

    @Test func aServerThatNeedsSignInCountsAsReached() async throws {
        let rpc = t3Gateway(test: { _ in oauthChallenge() })
        try await customService(rpc).checkT3Address("mac.tail1234.ts.net:3773")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test"])
    }

    @Test func aBadAddressNeverReachesTheGateway() async {
        let rpc = t3Gateway(test: okTools(["a"]))
        let error = await thrownError { try await customService(rpc).checkT3Address("http://example.com/mcp") }
        #expect(error as? T3AddressError == .insecure)
        #expect(rpc.methods().isEmpty)
        #expect(status(error)?.kind == .vendorRefusedValue)
    }

    @Test func anUnreachableServerIsRemovedAgainAndReportedAsUnreachable() async {
        let rpc = t3Gateway(test: testReply(reason: "unreachable"))
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
        #expect(status(error)?.kind == .serverUnreachable)
        #expect(status(error)?.title == "Pal could not reach T3 Code")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test", "mcp.servers.remove"])
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "t3code")
    }

    @Test func anAddressThatIsNotAnMcpServerIsRemovedAgainAndReportedAsSuch() async {
        let rpc = t3Gateway(test: testReply(reason: "not_mcp"))
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70:8080") }
        #expect(status(error)?.kind == .notMcpServer)
        #expect(status(error)?.title == "T3 Code did not answer like an MCP server")
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func anyOtherAnswerIsAnInternalFaultAndTheServerIsRemoved() async {
        let replies: [CustomRPC.Reply] = [testReply(reason: "server_error"), { _ in ["ok": false] }, testReply(reason: "something_new")]
        for reply in replies {
            let rpc = t3Gateway(test: reply)
            let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
            let result = status(error)
            #expect(result?.kind == .internalFault)
            #expect(result?.method == "mcp.servers.test")
            #expect(rpc.methods().last == "mcp.servers.remove")
        }
    }

    @Test func aBrokenConnectionToYourPalIsOfflineAndTheServerIsRemoved() async {
        let rpc = t3Gateway(test: { _ in throw GatewayTransportError.timedOut })
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
        #expect(status(error)?.kind == .offline)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aRefusedAddRemovesNothingBecauseNothingWasAdded() async {
        let rpc = t3Gateway(add: rpcFailure(4030, reason: "forbidden"), test: okTools(["a"]))
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
        #expect(status(error)?.kind == .forbidden)
        #expect(rpc.methods() == ["mcp.servers.add"])
    }

    @Test func anExistingServerIsUpdatedWithTheNewAddressThenTested() async throws {
        let rpc = t3Gateway(add: rpcFailure(4090), test: okTools(["a"]))
        try await customService(rpc).checkT3Address("100.109.203.71:4000")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.update", "mcp.servers.test"])
        let update = try #require(rpc.params("mcp.servers.update").first)
        #expect(update["name"]?.stringValue == "t3code")
        #expect(update["config"]?["url"]?.stringValue == "http://100.109.203.71:4000/mcp")
        #expect(update["config"]?["transport"]?.stringValue == "http")
    }

    @Test func aFailingCheckNeverRemovesAServerThatWasThereBefore() async {
        let rpc = t3Gateway(add: rpcFailure(4090), test: testReply(reason: "unreachable"))
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
        #expect(status(error)?.kind == .serverUnreachable)
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.update", "mcp.servers.test"])
    }

    @Test func aFailedUpdateStopsBeforeTestingAndRemovesNothing() async {
        let rpc = t3Gateway(add: rpcFailure(4090), update: rpcFailure(4030, reason: "forbidden"), test: okTools(["a"]))
        let error = await thrownError { try await customService(rpc).checkT3Address("100.109.203.70") }
        #expect(status(error)?.kind == .forbidden)
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.update"])
    }

    @Test func aCancelledSignInShowsNoFailureAndKeepsTheServer() async {
        let rpc = CustomRPC([
            "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": "https://auth.example.com/authorize"] },
            "mcp.servers.oauth.cancel": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
        ])
        let error = await thrownError { try await customService(rpc, system: IdleBrowser()).signInT3Code() }
        #expect(error is CancellationError)
        #expect(!rpc.methods().contains("mcp.servers.remove"))
        #expect(rpc.params("mcp.servers.oauth.start").first?["name"]?.stringValue == "t3code")
    }

    @Test func aServerThatRefusesOurRedirectReportsItAsSuch() async {
        let rpc = CustomRPC(["mcp.servers.oauth.start": rpcFailure(4002, message: "redirect_uri is not allowed")])
        let error = await thrownError { try await customService(rpc, system: IdleBrowser()).signInT3Code() }
        let result = status(error)
        #expect(result?.kind == .invalidRedirect)
        #expect(result?.title == "T3 Code would not accept this device's address")
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aSignInThatFailsForAnotherReasonSaysWhy() async {
        let rpc = CustomRPC(["mcp.servers.oauth.start": rpcFailure(4002, message: "access_denied")])
        let error = await thrownError { try await customService(rpc, system: IdleBrowser()).signInT3Code() }
        let result = status(error)
        #expect(result?.kind == .needsReauth)
        #expect(result?.actionTitle == "Reconnect")
        #expect(result?.reason == "Access was not granted.")
    }

    @Test func theProbeReadsOneTestResultAndNeverThrows() async {
        let cases: [(CustomRPC.Reply, T3Reach)] = [
            (okTools(["a"]), .reachable),
            ({ _ in oauthChallenge() }, .needsSignIn),
            ({ _ in ["ok": false, "reason": "auth_refused", "oauth_needed": false] }, .needsSignIn),
            (testReply(reason: "unreachable"), .unreachable),
            (testReply(reason: "not_mcp"), .unreachable),
            ({ _ in ["ok": false] }, .unreachable),
            ({ _ in throw GatewayTransportError.timedOut }, .unreachable),
        ]
        for (reply, expected) in cases {
            let rpc = CustomRPC(["mcp.servers.test": reply])
            let reach = await customService(rpc).probeT3Code()
            #expect(reach == expected)
            #expect(rpc.methods() == ["mcp.servers.test"])
        }
        #expect(await customService(CustomRPC([:])).probeT3Code() == .unreachable)
    }
}

@Suite("T3 Code wizard run")
@MainActor
struct T3CodeWizardRunTests {
    private func model(_ rpc: CustomRPC, resumeAt: T3CodeFlow.Resume?) throws -> StepFlowModel {
        let engine = try #require(T3CodeFlow.engine(resumeAt: resumeAt))
        let service = customService(rpc, system: IdleBrowser())
        return StepFlowModel(engine: engine, runner: T3CodeFlow.runner(service: service), classify: { T3CodeFlow.classify($0) })
    }

    @Test func aGoodAddressMovesOnToSignIn() async throws {
        let rpc = t3Gateway(test: okTools(["a"]))
        let wizard = try model(rpc, resumeAt: .address)
        wizard.setValue("100.109.203.70:3773", for: "address")
        await wizard.performPrimary()
        #expect(wizard.engine.current.id == "signin")
        #expect(wizard.engine.failure == nil)
        #expect(rpc.params("mcp.servers.add").first?["config"]?["url"]?.stringValue == "http://100.109.203.70:3773/mcp")
    }

    @Test func anUnreachableAddressStaysOnTheStepAndAsksForTheAddressAgain() async throws {
        let wizard = try model(t3Gateway(test: testReply(reason: "unreachable")), resumeAt: .address)
        wizard.setValue("100.109.203.70:3773", for: "address")
        await wizard.performPrimary()
        #expect(wizard.engine.current.id == "address")
        #expect(wizard.engine.failure?.kind == .serverUnreachable)
        #expect(wizard.engine.failure?.actionTitle == "Enter the address again")
        wizard.setValue("100.109.203.71:3773", for: "address")
        #expect(wizard.engine.failure == nil)
        #expect(wizard.engine.value(for: "address") == "100.109.203.71:3773")
    }

    @Test func closingTheBrowserEndsTheSignInStepWithoutAFailure() async throws {
        let rpc = CustomRPC([
            "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": "https://auth.example.com/authorize"] },
            "mcp.servers.oauth.cancel": { _ in ["ok": true] },
        ])
        let wizard = try model(rpc, resumeAt: .signIn)
        await wizard.performPrimary()
        #expect(wizard.engine.current.id == "signin")
        #expect(wizard.engine.failure == nil)
        #expect(wizard.engine.phase == .ready)
    }

    @Test func theFirstStepOnlyAdvancesAndTouchesNothing() async throws {
        let rpc = t3Gateway(test: okTools(["a"]))
        let wizard = try model(rpc, resumeAt: nil)
        await wizard.performPrimary()
        #expect(wizard.engine.current.id == "address")
        #expect(rpc.methods().isEmpty)
    }
}
