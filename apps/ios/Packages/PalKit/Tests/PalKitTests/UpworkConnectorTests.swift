import Foundation
import PalConnect
import PalDevice
import PalProtocol
import Synchronization
import Testing

private let rejectedSignIn = "Sign in again on a Mac: Upwork stopped accepting the saved sign-in"

private func upwork(_ state: ConnectAppState, reason: String? = nil) -> ConnectApp {
    ConnectApp(
        id: "mcp:upwork", name: "Upwork", summary: "", category: "Other", iconURL: nil,
        source: .mcp(name: "upwork", requires: []), state: state, authReason: reason
    )
}

private func resolve(_ state: ConnectAppState, platform: ConnectorPlatform, busy: Bool = false, failure: String? = nil, reason: String? = nil) -> ConnectorCardState {
    return .resolve(ConnectorCardInput(app: upwork(state, reason: reason), isBusy: busy, failureReason: failure), platform: platform)
}

@Suite("Connector card state")
struct ConnectorCardStateTests {
    @Test func macCanSignInFromEveryState() {
        #expect(resolve(.disconnected, platform: .mac) == .connect)
        #expect(resolve(.disconnected, platform: .mac, busy: true) == .connecting)
        #expect(resolve(.connected, platform: .mac) == .connected)
        #expect(resolve(.needsAuthorization, platform: .mac) == .reconnect(reason: nil))
        #expect(resolve(.disconnected, platform: .mac, failure: "Upwork refused it.") == .failed("Upwork refused it."))
        #expect(resolve(.disconnected, platform: .mac, failure: "") == .connect)
    }

    @Test func iPhoneNeverOffersAConnectThatWouldFail() {
        #expect(resolve(.disconnected, platform: .iPhone) == .signInOnMac(reason: nil))
        #expect(resolve(.needsAuthorization, platform: .iPhone) == .signInOnMac(reason: nil))
        #expect(resolve(.disconnected, platform: .iPhone, failure: "x") == .signInOnMac(reason: nil))
        #expect(resolve(.connected, platform: .iPhone) == .connected)
        #expect(resolve(.disconnected, platform: .iPhone, busy: true) == .connecting)
    }

    @Test func otherConnectorsKeepTheirOwnFlowOnIPhone() {
        let hosted = ConnectApp(
            id: "connector:slack", name: "Slack", summary: "", category: "Communication", iconURL: nil,
            source: .hosted(slug: "slack"), state: .disconnected
        )
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: hosted), platform: .iPhone) == .connect)
        let preset = ConnectApp(
            id: "mcp:notion", name: "Notion", summary: "", category: "Other", iconURL: nil,
            source: .mcp(name: "notion", requires: []), state: .needsAuthorization
        )
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: preset), platform: .iPhone) == .reconnect(reason: nil))
    }

    @Test func aRejectedSignInShowsTheGatewaysReasonOnEveryDevice() {
        #expect(resolve(.needsAuthorization, platform: .iPhone, reason: rejectedSignIn) == .signInOnMac(reason: rejectedSignIn))
        #expect(resolve(.needsAuthorization, platform: .mac, reason: rejectedSignIn) == .reconnect(reason: rejectedSignIn))
        #expect(resolve(.needsAuthorization, platform: .iPhone, reason: "  \n") == .signInOnMac(reason: nil))
        #expect(resolve(.needsAuthorization, platform: .mac, reason: "") == .reconnect(reason: nil))
    }

    @Test func onlyTheMacCanStartTheSignInAgain() {
        #expect(resolve(.needsAuthorization, platform: .mac, reason: rejectedSignIn).isReconnect)
        #expect(!resolve(.needsAuthorization, platform: .iPhone, reason: rejectedSignIn).isReconnect)
        #expect(resolve(.needsAuthorization, platform: .iPhone, reason: rejectedSignIn, busy: true) == .connecting)
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
        #expect(ConnectorCardState.resolve(ConnectorCardInput(app: app), platform: .iPhone) == .signInOnMac(reason: rejectedSignIn))
        #expect(!ConnectedServices(catalog: catalog).isConnected(.upwork))
    }

    @Test func aBlankReasonLeavesTheAppConnected() {
        let healthy = McpPresetEntry(name: "upwork", description: "", installed: true, enabled: true, needsAuthReason: nil)
        let blank = McpPresetEntry(name: "upwork", description: "", installed: true, enabled: true, needsAuthReason: "  ")
        #expect(ConnectCatalog.make(hosted: [], states: [], mcp: [healthy]).apps.first?.state == .connected)
        #expect(ConnectCatalog.make(hosted: [], states: [], mcp: [blank]).apps.first?.state == .connected)
    }

    @Test func onlyTheUpworkPresetNeedsTheMac() {
        #expect(upwork(.connected).requiresMacSignIn)
        let other = ConnectApp(id: "mcp:x", name: "X", summary: "", category: "", iconURL: nil, source: .mcp(name: "x", requires: []), state: .connected)
        #expect(!other.requiresMacSignIn)
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

@MainActor
@Suite("Mac-only sign-in dialog")
struct MacOnlySignInDialogTests {
    private func event(service: String = "mcp:upwork", signinOn: String? = "owner_app") -> GatewayEvent {
        var payload: [String: JSONValue] = [
            "request_id": "r1", "service": .string(service), "service_name": "Upwork", "bot": "atlas", "reason": "missing", "flow": "oauth",
        ]
        if let signinOn { payload["signin_on"] = .string(signinOn) }
        return GatewayEvent(type: "auth.required", payload: .object(payload))
    }

    @Test func iPhoneCannotSignInAndOffersNoSignInButton() {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in })
        center.receive(event())
        let dialog = center.current
        #expect(dialog?.requiresMac == true)
        #expect(dialog?.mustSignInOnMac == true)
        #expect(dialog?.canSignIn == false)
    }

    @Test func macRunsTheNativeFlowAndFinishesSignedIn() async {
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

    @Test func macShowsTheFailureReason() async {
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { _ in .failed("Upwork refused it.") },
            dismissDelay: .seconds(60)
        )
        center.receive(event())
        await center.signIn()
        #expect(center.current?.phase == .failed("Upwork refused it."))
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
        #expect(center.current?.requiresMac == false)
    }
}
