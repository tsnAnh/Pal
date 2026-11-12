import Foundation
import PalConnect
import PalDevice
import PalProtocol
import Synchronization
import Testing

private let rejectedSignIn = "Sign in again: Upwork stopped accepting the saved sign-in"

private func upwork(_ state: ConnectAppState, reason: String? = nil) -> ConnectApp {
    ConnectApp(
        id: "mcp:upwork", name: "Upwork", summary: "", category: "Other", iconURL: nil,
        source: .mcp(name: "upwork", requires: []), state: state, authReason: reason
    )
}

private func resolve(_ state: ConnectAppState, busy: Bool = false, failure: String? = nil, reason: String? = nil) -> ConnectorCardState {
    return .resolve(ConnectorCardInput(app: upwork(state, reason: reason), isBusy: busy, failureReason: failure))
}

@Suite("Connector card state")
struct ConnectorCardStateTests {
    @Test func everyStateIsReachableOnEveryDevice() {
        #expect(resolve(.disconnected) == .connect)
        #expect(resolve(.disconnected, busy: true) == .connecting)
        #expect(resolve(.connected) == .connected)
        #expect(resolve(.needsAuthorization) == .reconnect(reason: nil))
        #expect(resolve(.disconnected, failure: "Upwork refused it.") == .failed("Upwork refused it."))
        #expect(resolve(.disconnected, failure: "") == .connect)
    }

    @Test func otherConnectorsKeepTheirOwnFlow() {
        let hosted = ConnectApp(
            id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil,
            source: .hosted(slug: "slack"), state: .disconnected
        )
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: hosted)) == .connect)
        let preset = ConnectApp(
            id: "mcp:notion", name: "Notion", summary: "", category: "Other", iconURL: nil,
            source: .mcp(name: "notion", requires: []), state: .needsAuthorization
        )
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: preset)) == .reconnect(reason: nil))
    }

    @Test func aRejectedSignInShowsTheGatewaysReasonWithReconnect() {
        #expect(resolve(.needsAuthorization, reason: rejectedSignIn) == .reconnect(reason: rejectedSignIn))
        #expect(resolve(.needsAuthorization, reason: "  \n") == .reconnect(reason: nil))
        #expect(resolve(.needsAuthorization, reason: "") == .reconnect(reason: nil))
        #expect(resolve(.needsAuthorization, reason: rejectedSignIn).isReconnect)
        #expect(resolve(.needsAuthorization, reason: rejectedSignIn, busy: true) == .connecting)
    }

    @Test func everyDeviceHasARouteToSignInAgain() {
        for platform in ConnectorPlatform.allCases {
            #expect(platform.signInRoutes.contains(.pasteAddress))
        }
        #expect(ConnectorPlatform.mac.signInRoutes == [.automaticReturn, .pasteAddress])
        #expect(ConnectorPlatform.iPhone.signInRoutes == [.pasteAddress])
        #expect(ConnectorPlatform.iPad.signInRoutes == [.pasteAddress])
        #expect(ConnectorPlatform.mac.returnsAutomatically)
        #expect(!ConnectorPlatform.iPhone.returnsAutomatically)
        #expect(!ConnectorPlatform.iPad.returnsAutomatically)
    }

    @Test func theCatalogReadsTheReasonFromTheStatusTheGatewayGives() throws {
        let decoded = try JSONDecoder().decode(
            McpPresetEntry.self,
            from: Data(#"{"name":"upwork","description":"","installed":true,"enabled":true,"needs_auth_reason":"\#(rejectedSignIn)"}"#.utf8)
        )
        let catalog = ConnectCatalog.make(hosted: [], states: [], mcp: [decoded])
        let app = try #require(catalog.apps.first)
        #expect(app.state == .needsAuthorization)
        #expect(app.authReason == rejectedSignIn)
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: app)) == .reconnect(reason: rejectedSignIn))
        #expect(!ConnectedServices(catalog: catalog).isConnected(.upwork))
    }

    @Test func aBlankReasonLeavesTheAppConnected() {
        let healthy = McpPresetEntry(name: "upwork", description: "", installed: true, enabled: true, needsAuthReason: nil)
        let blank = McpPresetEntry(name: "upwork", description: "", installed: true, enabled: true, needsAuthReason: "  ")
        #expect(ConnectCatalog.make(hosted: [], states: [], mcp: [healthy]).apps.first?.state == .connected)
        #expect(ConnectCatalog.make(hosted: [], states: [], mcp: [blank]).apps.first?.state == .connected)
    }

    @Test func onlyTheUpworkPresetUsesTheAppSignIn() {
        #expect(upwork(.connected).requiresAppSignIn)
        let other = ConnectApp(id: "mcp:x", name: "X", summary: "", category: "", iconURL: nil, source: .mcp(name: "x", requires: []), state: .connected)
        #expect(!other.requiresAppSignIn)
    }
}

@Suite("Upwork as a connected service")
struct UpworkConnectedServiceTests {
    @Test func countsAsConnectedWhenThePresetIsInstalledAndEnabled() {
        let on = ConnectCatalog.make(hosted: [], states: [], mcp: [McpPresetEntry(name: "upwork", description: "", installed: true, enabled: true)])
        let off = ConnectCatalog.make(hosted: [], states: [], mcp: [McpPresetEntry(name: "upwork", description: "")])
        #expect(ConnectedServices(catalog: on).isConnected(.upwork))
        #expect(!ConnectedServices(catalog: off).isConnected(.upwork))
        #expect(!ConnectedServices.unknown.isConnected(.upwork))
    }
}

private final class AutoApproveRPC: @unchecked Sendable {
    private let log = Mutex<[(String, JSONValue)]>([])
    var enabled = false
    var eligible = true
    var failing = false

    var calls: [(String, JSONValue)] { log.withLock { $0 } }

    func handle(_ method: String, _ params: JSONValue?) throws -> JSONValue {
        log.withLock { $0.append((method, params ?? .null)) }
        if failing { throw StubFailure() }
        if method == "mcp.actions.auto_approve.set" {
            enabled = params?["enabled"]?.boolValue ?? false
            return ["enabled": .bool(enabled)]
        }
        return ["enabled": .bool(enabled), "eligible": .bool(eligible)]
    }
}

private struct StubFailure: Error {}

@MainActor
@Suite("Per-chat auto-approve")
struct ActionAutoApproveTests {
    private func model(_ rpc: AutoApproveRPC) -> ActionAutoApprove {
        ActionAutoApprove { method, params in try rpc.handle(method, params) }
    }

    @Test func startsOffAndHiddenUntilTheGatewayAnswers() {
        let approve = model(AutoApproveRPC())
        #expect(!approve.showsSwitch(sessionID: "s1", upworkConnected: true))
        #expect(!approve.showsBanner(sessionID: "s1"))
    }

    @Test func switchNeedsAConnectedUpworkAndAnEligibleChat() async {
        let rpc = AutoApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1")
        #expect(approve.showsSwitch(sessionID: "s1", upworkConnected: true))
        #expect(!approve.showsSwitch(sessionID: "s1", upworkConnected: false))
        rpc.eligible = false
        await approve.load(sessionID: "s1")
        #expect(!approve.showsSwitch(sessionID: "s1", upworkConnected: true))
    }

    @Test func readsWithTheServerAndSessionOnOpen() async throws {
        let rpc = AutoApproveRPC()
        await model(rpc).load(sessionID: "s1")
        let (method, params) = try #require(rpc.calls.first)
        #expect(method == "mcp.actions.auto_approve.get")
        #expect(params["session_id"]?.stringValue == "s1")
        #expect(params["server"]?.stringValue == "mcp:upwork")
    }

    @Test func turningOnShowsTheBannerAndOffRemovesIt() async throws {
        let rpc = AutoApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1")
        #expect(await approve.setEnabled(true, sessionID: "s1"))
        #expect(approve.showsBanner(sessionID: "s1"))
        let (method, params) = try #require(rpc.calls.last)
        #expect(method == "mcp.actions.auto_approve.set")
        #expect(params["enabled"]?.boolValue == true)
        #expect(params["server"]?.stringValue == "mcp:upwork")
        #expect(await approve.setEnabled(false, sessionID: "s1"))
        #expect(!approve.showsBanner(sessionID: "s1"))
        #expect(approve.showsSwitch(sessionID: "s1", upworkConnected: true))
    }

    @Test func aFailedTurnOffKeepsTheBannerAndFlagsTheError() async {
        let rpc = AutoApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "s1")
        _ = await approve.setEnabled(true, sessionID: "s1")
        rpc.failing = true
        #expect(!(await approve.setEnabled(false, sessionID: "s1")))
        #expect(approve.showsBanner(sessionID: "s1"))
        #expect(approve.didFail("s1"))
        rpc.failing = false
        #expect(await approve.setEnabled(false, sessionID: "s1"))
        #expect(!approve.didFail("s1"))
    }

    @Test func eachChatKeepsItsOwnState() async {
        let rpc = AutoApproveRPC()
        let approve = model(rpc)
        await approve.load(sessionID: "a")
        _ = await approve.setEnabled(true, sessionID: "a")
        rpc.enabled = false
        await approve.load(sessionID: "b")
        #expect(approve.showsBanner(sessionID: "a"))
        #expect(!approve.showsBanner(sessionID: "b"))
    }

    @Test func aGatewayThatCannotAnswerShowsNothing() async {
        let rpc = AutoApproveRPC()
        rpc.failing = true
        let approve = model(rpc)
        await approve.load(sessionID: "s1")
        #expect(!approve.showsSwitch(sessionID: "s1", upworkConnected: true))
        #expect(!approve.showsBanner(sessionID: "s1"))
    }

    @Test func forgetClearsEverythingOnSignOut() async {
        let approve = model(AutoApproveRPC())
        await approve.load(sessionID: "s1")
        _ = await approve.setEnabled(true, sessionID: "s1")
        approve.forget()
        #expect(!approve.showsBanner(sessionID: "s1"))
    }
}

private final class PasteRecorder: @unchecked Sendable {
    private let log = Mutex<[String]>([])
    var begun: [String] { log.withLock { $0 } }
    func note(_ entry: String) { log.withLock { $0.append(entry) } }
}

@MainActor
@Suite("App sign-in dialog")
struct AppSignInDialogTests {
    private func event(service: String = "mcp:upwork", signinOn: String? = "owner_app") -> GatewayEvent {
        var payload: [String: JSONValue] = [
            "request_id": "r1", "service": .string(service), "service_name": "Upwork", "bot": "atlas", "reason": "missing", "flow": "oauth",
        ]
        if let signinOn { payload["signin_on"] = .string(signinOn) }
        return GatewayEvent(type: "auth.required", payload: .object(payload))
    }

    private func pasteRoute(_ recorder: PasteRecorder, begin: String? = nil, submit: ServicePasteOutcome = .signedIn) -> ServicePasteSignIn {
        return ServicePasteSignIn(
            begin: { service in
                recorder.note("begin:\(service)")
                return begin
            },
            submit: { service, _ in
                recorder.note("submit:\(service)")
                return submit
            },
            cancel: { service in recorder.note("cancel:\(service)") },
            reopen: { service in recorder.note("reopen:\(service)") }
        )
    }

    @Test func theWireHintIsOwnerApp() {
        #expect(ServiceSignInWire.ownerApp == "owner_app")
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in })
        center.receive(event())
        #expect(center.current?.requiresAppSignIn == true)
        center.receive(event(service: "github", signinOn: "owner_app"))
        #expect(center.dialogs.last?.requiresAppSignIn == false)
    }

    @Test func aDeviceWithNoRouteOffersNoSignInButton() {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in })
        center.receive(event())
        #expect(center.current?.canSignIn == false)
    }

    @Test func anIPhoneWithOnlyThePasteRouteCanSignIn() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, pasteSignIn: pasteRoute(recorder), dismissDelay: .seconds(60))
        center.receive(event())
        #expect(center.current?.canSignIn == true)
        #expect(center.current?.automaticSignInAvailable == false)
        await center.signIn()
        #expect(center.current?.phase == .pasteAddress(nil))
        center.reopenSignInPage()
        await center.submitAddress("http://127.0.0.1:50000/callback?code=c&state=s")
        #expect(center.current?.phase == .signedIn)
        #expect(recorder.begun == ["begin:mcp:upwork", "reopen:mcp:upwork", "submit:mcp:upwork"])
    }

    @Test func aPasteTheAppCannotUseAsksAgainWithoutLeavingTheStep() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            pasteSignIn: pasteRoute(recorder, submit: .tryAgain("Copy the whole address.")), dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        await center.submitAddress("junk")
        #expect(center.current?.phase == .pasteAddress("Copy the whole address."))
    }

    @Test func aFailedPasteShowsItsReason() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            pasteSignIn: pasteRoute(recorder, submit: .failed("Start again.")), dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        await center.submitAddress("http://127.0.0.1:50000/callback?code=c&state=wrong")
        #expect(center.current?.phase == .failed("Start again."))
    }

    @Test func aBrowserThatCannotOpenFailsTheStep() async {
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            pasteSignIn: pasteRoute(PasteRecorder(), begin: "We couldn't open your browser."), dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        #expect(center.current?.phase == .failed("We couldn't open your browser."))
    }

    @Test func submittingOutsideThePasteStepDoesNothing() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, pasteSignIn: pasteRoute(recorder), dismissDelay: .seconds(60))
        center.receive(event())
        await center.submitAddress("anything")
        #expect(recorder.begun.isEmpty)
        #expect(center.current?.phase == .prompting)
    }

    @Test func notNowCancelsThePendingPaste() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, pasteSignIn: pasteRoute(recorder), dismissDelay: .seconds(60))
        center.receive(event())
        await center.signIn()
        await center.notNow()
        #expect(center.current == nil)
        #expect(recorder.begun.last == "cancel:mcp:upwork")
    }

    @Test func macRunsTheAutomaticFlowAndFinishesSignedIn() async {
        let ran = Mutex<[String]>([])
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { service in
                ran.withLock { $0.append(service) }
                return .signedIn
            },
            dismissDelay: .seconds(60)
        )
        center.receive(event())
        #expect(center.current?.canSignIn == true)
        await center.signIn()
        #expect(ran.withLock { $0 } == ["mcp:upwork"])
        #expect(center.current?.phase == .signedIn)
    }

    @Test func macOffersThePasteRouteAfterTheAutomaticOneFails() async {
        let recorder = PasteRecorder()
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { _ in .failed("Sign-in took too long and was stopped.") },
            pasteSignIn: pasteRoute(recorder), dismissDelay: .seconds(60)
        )
        center.receive(event())
        #expect(center.current?.canPasteInstead == false)
        await center.signIn()
        #expect(center.current?.phase == .failed("Sign-in took too long and was stopped."))
        #expect(center.current?.canPasteInstead == true)
        await center.signInByPasting()
        #expect(center.current?.phase == .pasteAddress(nil))
        #expect(recorder.begun == ["begin:mcp:upwork"])
    }

    @Test func macShowsTheFailureReason() async {
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { _ in .failed("Upwork refused it.") },
            dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        #expect(center.current?.phase == .failed("Upwork refused it."))
        #expect(center.current?.canPasteInstead == false)
    }

    @Test func cancellingReturnsToThePromptSoItCanBeRetried() async {
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { _ in .cancelled },
            dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        #expect(center.current?.phase == .prompting)
    }

    @Test func otherServicesKeepTheirOwnFlow() {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in })
        center.receive(event(service: "github", signinOn: nil))
        #expect(center.current?.requiresAppSignIn == false)
    }
}
