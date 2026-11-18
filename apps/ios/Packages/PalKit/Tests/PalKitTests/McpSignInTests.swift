import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Testing

private let authLink = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Fcallback"
private let pasted = "http://127.0.0.1:50123/callback?code=abc&state=st-1"

private func notion(state: ConnectAppState = .disconnected) -> ConnectApp {
    ConnectApp(id: "mcp:notion", name: "Notion", summary: "", category: "Other", source: .mcp(name: "notion", requires: []), state: state)
}

private func upwork() -> ConnectApp {
    ConnectApp(id: "mcp:upwork", name: "Upwork", summary: "", category: "Other", source: .mcp(name: "upwork", requires: []), state: .disconnected)
}

private func refusal(_ message: String, reason: String? = nil) -> CustomRPC.Reply {
    { _ in
        var data: [String: JSONValue] = ["trace": "is6jx82q"]
        if let reason { data["reason"] = .string(reason) }
        throw GatewayTransportError.rpc(RPCError(code: 5000, message: message, data: .object(data)))
    }
}

private func gateway(start: @escaping CustomRPC.Reply = { _ in ["session_id": "s1", "auth_url": .string(authLink)] }) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.oauth.start": start,
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { _ in ["status": "approved"] },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

@MainActor
private final class Probe {
    var finished = 0
    var opened: [URL] = []
    var canOpen = true
}

@MainActor
private func makeController(
    _ rpc: CustomRPC, probe: Probe, app: ConnectApp = notion(), platform: ConnectorPlatform = .iPhone
) -> McpSignInController {
    McpSignInController(
        app: app, service: customService(rpc), platform: platform,
        openLink: { url in
            probe.opened.append(url)
            return probe.canOpen
        },
        finished: { probe.finished += 1 }
    )
}

private func failure(_ phase: McpSignInPhase) -> SetupStatus? {
    if case .failed(let status) = phase { status } else { nil }
}

@MainActor
@Suite("Plain MCP sign-in sheet")
struct McpSignInControllerTests {
    @Test func aRefusedRedirectShowsTheCodeTheMethodAndTheTrace() async throws {
        let rpc = gateway(start: refusal("redirect_uri is not allowed"))
        let probe = Probe()
        let sheet = makeController(rpc, probe: probe)
        await sheet.start()
        let status = try #require(failure(sheet.phase))
        #expect(status.kind == .invalidRedirect)
        #expect(status.code == "invalid_redirect_uri")
        #expect(status.method == "mcp.servers.oauth.start")
        #expect(status.trace == "is6jx82q")
        #expect(status.title == "Notion would not accept this iPhone's address")
        #expect(rpc.methods().last == "mcp.servers.remove")
        #expect(probe.finished == 0)
    }

    @Test func aStaleFlowIsClearedAndTheNextTryConnects() async throws {
        let calls = CallCounter()
        let rpc = gateway { _ in
            if calls.next() == 1 {
                throw GatewayTransportError.rpc(RPCError(code: 5024, message: "a sign-in is already open", data: ["reason": "oauth_in_progress"]))
            }
            return ["session_id": "s2", "auth_url": .string(authLink)]
        }
        let probe = Probe()
        let sheet = makeController(rpc, probe: probe)
        await sheet.start()
        let status = try #require(failure(sheet.phase))
        #expect(status.kind == .signInInProgress)
        #expect(status.code == "oauth_in_progress")
        #expect(status.actionTitle == "Connect")
        await sheet.retry()
        #expect(sheet.phase == .pasteAddress)
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.start" }.count == 2)
        await sheet.submit(pasted)
        #expect(sheet.phase == .signedIn)
        #expect(probe.finished == 1)
    }

    @Test func aRetryIsIgnoredWhileNothingFailed() async {
        let rpc = gateway()
        let sheet = makeController(rpc, probe: Probe())
        await sheet.start()
        await sheet.retry()
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.start" }.count == 1)
    }

    @Test func startingTwiceRunsOneSignIn() async {
        let rpc = gateway()
        let sheet = makeController(rpc, probe: Probe())
        await sheet.start()
        await sheet.start()
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.start" }.count == 1)
    }

    @Test func anAdminApprovalWaitIsCalmAndRemovesTheServerItAdded() async {
        let rpc = gateway(start: refusal("Admin approval is required for this application"))
        let sheet = makeController(rpc, probe: Probe())
        await sheet.start()
        #expect(sheet.phase == .waitingForAdmin)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aGatewayReasonWeHaveNoWordsForStillShowsItsCode() async throws {
        let sheet = makeController(gateway(start: refusal("boom", reason: "disk_full")), probe: Probe())
        await sheet.start()
        let status = try #require(failure(sheet.phase))
        #expect(status.kind == .signInIncomplete)
        #expect(status.code == "sign_in_failed")
        #expect(status.reason == McpSignInFailure.other.reason)
        #expect(status.trace == "is6jx82q")
    }

    @Test func aBrowserThatWillNotOpenFailsPlainlyAndCancelsTheFlow() async throws {
        let rpc = gateway()
        let probe = Probe()
        probe.canOpen = false
        let sheet = makeController(rpc, probe: probe)
        await sheet.start()
        let status = try #require(failure(sheet.phase))
        #expect(status.code == "browser_unavailable")
        #expect(status.reason == McpOAuthError.browserUnavailable.reason)
        #expect(rpc.methods().contains("mcp.servers.oauth.cancel"))
    }

    @Test func thePasteRouteOpensTheSignInPageOnceAndReopensItOnRequest() async {
        let probe = Probe()
        let sheet = makeController(gateway(), probe: probe)
        await sheet.start()
        #expect(sheet.phase == .pasteAddress)
        #expect(probe.opened.map(\.absoluteString) == [authLink])
        sheet.reopen()
        #expect(probe.opened.count == 2)
    }

    @Test func anAddressWithoutACodeIsNeverSentToThePal() async {
        let rpc = gateway()
        let sheet = makeController(rpc, probe: Probe())
        await sheet.start()
        await sheet.submit("http://127.0.0.1:50123/callback")
        await sheet.submit("not an address")
        #expect(sheet.phase == .pasteAddress)
        #expect(!rpc.methods().contains("mcp.servers.oauth.callback"))
    }

    @Test func cancellingWhilePastingEndsTheGatewayFlowAndClosesTheSheet() async {
        let rpc = gateway()
        let sheet = makeController(rpc, probe: Probe())
        await sheet.start()
        await sheet.cancel()
        #expect(sheet.phase == .dismissed)
        #expect(rpc.methods().contains("mcp.servers.oauth.cancel"))
        #expect(rpc.methods().last == "mcp.servers.remove")
        await sheet.cancel()
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.cancel" }.count == 1)
    }

    @Test func aSheetClosedAfterSuccessStaysConnected() async {
        let sheet = makeController(gateway(), probe: Probe())
        await sheet.start()
        await sheet.submit(pasted)
        await sheet.cancel()
        #expect(sheet.phase == .signedIn)
    }

    @Test func upworkSignsInThroughTheNativeFlowNotTheGatewayStart() async throws {
        let rpc = gateway()
        let sheet = makeController(rpc, probe: Probe(), app: upwork(), platform: .mac)
        await sheet.start()
        #expect(failure(sheet.phase) != nil)
        #expect(!rpc.methods().contains("mcp.servers.oauth.start"))
    }
}

@Suite("Plain MCP sign-in status mapping")
struct McpSignInStatusTests {
    private func resolve(_ error: any Error) -> McpSignInResolution {
        McpSignInStatus.resolve(error, vendor: "Linear", platform: .mac)
    }

    private func status(_ error: any Error) -> SetupStatus? {
        if case .failed(let status) = resolve(error) { status } else { nil }
    }

    @Test func aCancelledSignInClosesWithoutAFailure() {
        #expect(resolve(ConnectAppsError.cancelled) == .dismissed)
        #expect(resolve(CancellationError()) == .dismissed)
        #expect(resolve(ConnectAppsError.signInFailed(McpOAuthError.cancelled.reason)) == .dismissed)
    }

    @Test func eachPlainFailureKeepsItsSentenceAndOwnCode() {
        let table: [(String, String)] = [
            (McpSignInFailure.denied.reason, "access_denied"),
            (McpSignInFailure.expired.reason, "sign_in_expired"),
            (McpOAuthError.browserUnavailable.reason, "browser_unavailable"),
            (McpOAuthError.timedOut.reason, "sign_in_timed_out"),
            (McpOAuthError.registrationFailed.reason, "invalid_client_metadata"),
            (McpOAuthError.handshakeUsed.reason, "handshake_used"),
            ("Something nobody wrote a table row for.", "sign_in_failed"),
        ]
        for (reason, code) in table {
            let result = status(ConnectAppsError.signInFailed(reason))
            #expect(result?.code == code)
            #expect(result?.kind != .internalFault)
        }
        #expect(status(ConnectAppsError.signInFailed(McpSignInFailure.denied.reason))?.reason == McpSignInFailure.denied.reason)
    }

    @Test func aRejectedRegistrationReadsAsTheAddressMessage() {
        let result = status(ConnectAppsError.signInFailed(McpOAuthError.registrationFailed.reason))
        #expect(result?.title == "Linear would not accept this Mac's address")
    }

    @Test func aGatewayFaultKeepsItsOwnReasonAndTrace() throws {
        let trace = try #require(TraceID("gj43o07j"))
        let fault = GatewayFault(code: 4030, reason: "forbidden", trace: trace, method: "mcp.servers.add", source: .gateway, gatewayVersion: "bbf2401c")
        let result = status(ConnectAppsError.faulted(fault))
        #expect(result?.kind == .forbidden)
        #expect(result?.detailsText(appBuild: "1.0 (1)") == "code: forbidden\nmethod: mcp.servers.add\ntrace: gj43o07j\napp: 1.0 (1) · gateway bbf2401c")
    }

    @Test func aGatewayThatCannotBeReachedSaysOffline() {
        #expect(status(ConnectAppsError.failed)?.kind == .offline)
        #expect(status(ConnectAppsError.signInFailed(McpOAuthError.gatewayUnavailable.reason))?.kind == .offline)
    }

    @Test func anUnknownErrorStillShowsACode() {
        let result = status(URLError(.badServerResponse))
        #expect(result?.kind == .internalFault)
        #expect(result?.code == "internal")
    }

    @Test func everyCodeWeWriteLandsInAClassThatIsNotTheCatchAll() {
        let codes = McpSignInFailure.allCases.map(\.code) + [
            McpOAuthError.discoveryFailed, .listenerFailed, .stateMismatch, .tokenExchangeFailed, .rejectedByGateway(nil), .serverAddFailed(nil),
        ].map(\.code)
        for code in codes where code != "admin_approval_required" {
            #expect(SetupStatusClass.classify(code: code) != .internalFault, "\(code)")
        }
    }

    @Test func adminWordsInTheProviderTextMeanAWaitNotAFailure() {
        #expect(McpSignInFailure.classify("AADSTS90094: admin consent required") == .adminApproval)
        #expect(McpSignInFailure.classify("Needs admin approval") == .adminApproval)
        #expect(McpSignInFailure.classify("administrator rights are not required") == .other)
        #expect(McpSignInFailure.classify("access_denied") == .denied)
    }
}

@Suite("Plain MCP sign-in steps and paste check")
struct McpSignInStepsTests {
    @Test func theSheetShowsThreeStepsWithSignInCurrent() throws {
        let engine = try #require(McpSignInSteps.engine(vendor: "Cloudflare"))
        #expect(engine.positionLabel == "Step 2 of 3")
        #expect(engine.checklist.map(\.title) == ["Open the vendor", "Sign in", "Back in Pal"])
        #expect(engine.checklist.map(\.state) == [.done, .current, .upcoming])
        #expect(engine.checklist.allSatisfy { !$0.isAutomatic })
        if case .browserRoundTrip(let title, let body) = engine.current.kind {
            #expect(title == "Waiting for you in the browser")
            #expect(body == "Sign in to Cloudflare and click Allow. You come back to Pal on your own.")
        } else {
            Issue.record("the sign-in step is the browser round trip")
        }
    }

    @Test func everyBrowserSignInAppUsesTheSheetAndNoOtherAppDoes() {
        let entry = PalCatalogEntry(slug: "linear", name: "Linear", method: .mcpOAuth)
        let keyed = PalCatalogEntry(slug: "github", name: "GitHub", method: .apiKey)
        func app(_ source: ConnectAppSource) -> ConnectApp {
            ConnectApp(id: "x", name: "X", summary: "", category: "", source: source, state: .disconnected)
        }
        #expect(app(.catalog(entry)).usesMcpSignIn)
        #expect(app(.mcp(name: "upwork", requires: [])).usesMcpSignIn)
        #expect(!app(.mcp(name: "stripe", requires: ["STRIPE_KEY"])).usesMcpSignIn)
        #expect(!app(.catalog(keyed)).usesMcpSignIn)
        #expect(!app(.googleWorkspace).usesMcpSignIn)
    }

    @Test(arguments: [
        ("", McpPasteShape.empty), ("   ", .empty), ("hello", .notAnAddress), ("ftp://127.0.0.1/callback?code=a", .notAnAddress),
        ("http://127.0.0.1:50123/callback", .missingCode), ("http://127.0.0.1:50123/callback?code=a&state=b", .valid),
        (" http://127.0.0.1:50123/callback?error=access_denied ", .valid),
    ])
    func theAddressIsCheckedAsItIsTyped(text: String, shape: McpPasteShape) {
        #expect(McpPasteShape.of(text) == shape)
        #expect((shape == .empty) == (shape.message == nil))
    }
}
