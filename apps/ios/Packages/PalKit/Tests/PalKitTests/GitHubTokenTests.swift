import Foundation
import Synchronization
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func statusJSON(_ state: String, login: String? = nil, scopes: [String] = [], missing: [String] = []) -> JSONValue {
    var object: [String: JSONValue] = [
        "state": .string(state), "scopes": .array(scopes.map { .string($0) }), "missing_scopes": .array(missing.map { .string($0) }),
        "token_kind": "classic", "git_protocol": "https",
    ]
    if let login { object["login"] = .string(login) }
    return .object(object)
}

private func startJSON(session: String = "s1", uri: String = "https://github.com/login/device", interval: Int = 5, expires: Int = 900) -> JSONValue {
    ["session_id": .string(session), "user_code": "ABCD-1234", "verification_uri": .string(uri), "expires_in": .int(expires), "interval": .int(interval)]
}

private func pollJSON(_ state: String, login: String? = nil, interval: Int? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["state": .string(state)]
    if let login { object["login"] = .string(login) }
    if let interval { object["interval"] = .int(interval) }
    return .object(object)
}

private final class Sleeps: Sendable {
    private let log = Mutex<[Duration]>([])
    var recorded: [Duration] { log.withLock { $0 } }
    var sleep: @Sendable (Duration) async throws -> Void { { [self] duration in log.withLock { $0.append(duration) } } }
}

@MainActor
private func model(_ bots: ScriptedBots, sleeps: Sleeps = Sleeps()) -> GitHubTokenModel {
    GitHubTokenModel(client: GitHubTokenClient(gateway: bots.gateway), surfaces: scratchSurfaces(), sleep: sleeps.sleep)
}

private let methodNotFound = GatewayTransportError.rpc(RPCError(code: -32601, message: "method not found"))

@Suite("GitHub for this machine")
@MainActor
struct GitHubTokenTests {
    @Test("every status state maps to its row text")
    func stateText() {
        #expect(GitHubTokenStatus(statusJSON("set", login: "octo")).headline == "Signed in as octo")
        #expect(GitHubTokenStatus(statusJSON("set")).headline == "Signed in")
        #expect(GitHubTokenStatus(statusJSON("missing")).headline == "Not signed in")
        #expect(GitHubTokenStatus(statusJSON("invalid")).headline == "Invalid")
        #expect(GitHubTokenStatus(statusJSON("expired")).headline == "Expired")
        #expect(GitHubTokenStatus(statusJSON("missing_scopes", missing: ["workflow"])).headline == "Missing scopes: workflow")
        #expect(GitHubTokenStatus(statusJSON("oauth_app_not_configured")).headline == "OAuth app not configured")
        #expect(GitHubTokenStatus(statusJSON("unknown")).headline == "Unknown")
        #expect(GitHubTokenStatus(statusJSON("set", login: "octo", scopes: ["repo", "workflow"])).detail == "Scopes: repo, workflow")
        #expect(GitHubTokenStatus(statusJSON("set", login: "octo")).detail == nil)
    }

    @Test("unknown fields are ignored and unreadable ones become unknown, never a guess")
    func tolerantDecoding() {
        let odd = GitHubTokenStatus(["state": "from_the_future", "login": 7, "scopes": "repo", "extra": true])
        #expect(odd.state == .unknown)
        #expect(odd.login == nil)
        #expect(odd.scopes.isEmpty)
        #expect(GitHubTokenStatus(JSONValue.null).state == .unknown)
        #expect(GitHubOAuthCode(["session_id": "s", "user_code": "X", "verification_uri": "http://github.com"]) == nil)
        #expect(GitHubOAuthCode(["session_id": "s", "user_code": "X"]) == nil)
        #expect(GitHubOAuthPoll(["state": "from_the_future"]) == .failed(message: nil))
        #expect(GitHubOAuthPoll(["state": "pending", "interval": 0]) == .pending(interval: 1))
    }

    @Test("refresh reads github.token.status")
    func refresh() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("set", login: "octo"))
        let github = model(bots)
        #expect(github.headline == "Checking…")
        await github.refresh()
        #expect(github.headline == "Signed in as octo")
        #expect(github.canSignIn)
    }

    @Test("not configured asks for the client ID and offers no sign-in")
    func notConfigured() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("oauth_app_not_configured"))
        let github = model(bots)
        await github.refresh()
        #expect(github.needsClientID)
        #expect(!github.canSignIn)
        await github.beginSignIn()
        #expect(github.signIn == nil)
        #expect(bots.calls(to: "github.oauth.start").isEmpty)
    }

    @Test("method-not-found is the plain unsupported state")
    func olderGateway() async {
        let bots = ScriptedBots()
        bots.script("github.token.status") { _ in throw methodNotFound }
        let github = model(bots)
        await github.refresh()
        #expect(github.phase == .unsupported)
        #expect(github.footnote == "This gateway does not support this yet.")
        #expect(!github.canSignIn)
    }

    @Test("a failing check shows unknown and keeps the last good state")
    func unavailable() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.token.status") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let github = model(bots)
        await github.refresh()
        await github.refresh()
        #expect(github.status?.state == .missing)
        let fresh = ScriptedBots()
        fresh.script("github.token.status") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let other = model(fresh)
        await other.refresh()
        #expect(other.phase == .unavailable)
        #expect(other.headline == "Unknown")
        #expect(other.canSignIn)
    }

    @Test("sign-in polls at the interval, then refreshes the status")
    func signInSucceeds() async {
        let bots = ScriptedBots()
        let sleeps = Sleeps()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON(interval: 3))
        bots.script("github.oauth.poll", pollJSON("pending"))
        bots.script("github.oauth.poll", pollJSON("signed_in", login: "octo"))
        bots.script("github.token.status", statusJSON("set", login: "octo"))
        let github = model(bots, sleeps: sleeps)
        await github.refresh()
        await github.beginSignIn()
        guard case .code(let code) = github.signIn else { Issue.record("no code"); return }
        #expect(code.userCode == "ABCD-1234")
        #expect(github.headline == "Waiting for approval")
        await github.pollTask?.value
        #expect(github.signIn == .signedIn(login: "octo"))
        #expect(sleeps.recorded == [.seconds(3), .seconds(3)])
        #expect(github.headline == "Signed in as octo")
        await github.closeSignIn()
        #expect(github.signIn == nil)
    }

    @Test("slow_down: the interval the gateway returns is used for the next poll")
    func slowInterval() async {
        let bots = ScriptedBots()
        let sleeps = Sleeps()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON(interval: 5))
        bots.script("github.oauth.poll", pollJSON("pending", interval: 10))
        bots.script("github.oauth.poll", pollJSON("pending", interval: 15))
        bots.script("github.oauth.poll", pollJSON("denied"))
        let github = model(bots, sleeps: sleeps)
        await github.refresh()
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(sleeps.recorded == [.seconds(5), .seconds(10), .seconds(15)])
    }

    @Test("denied, expired and organization approval end the flow and show on the row")
    func terminalOutcomes() async {
        let cases: [(String, GitHubTokenModel.SignIn, String)] = [
            ("denied", .denied, "Denied"),
            ("expired", .expired, "Expired"),
            ("org_approval_needed", .organizationApproval, "Organization approval needed"),
        ]
        for (wire, outcome, headline) in cases {
            let bots = ScriptedBots()
            bots.script("github.token.status", statusJSON("missing"))
            bots.script("github.oauth.start", startJSON())
            bots.script("github.oauth.poll", pollJSON(wire))
            let github = model(bots)
            await github.refresh()
            await github.beginSignIn()
            await github.pollTask?.value
            #expect(github.signIn == outcome)
            #expect(github.headline == headline)
            await github.closeSignIn()
            #expect(github.headline == headline)
            await github.refresh()
            #expect(github.headline == "Not signed in")
        }
    }

    @Test("the code expires after expires_in even if the gateway keeps saying pending")
    func localExpiry() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON(interval: 5, expires: 10))
        bots.script("github.oauth.poll", pollJSON("pending"))
        let github = model(bots)
        await github.refresh()
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(github.signIn == .expired)
    }

    @Test("retry after a terminal outcome starts a new session")
    func retry() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON(session: "s1"))
        bots.script("github.oauth.start", startJSON(session: "s2"))
        bots.script("github.oauth.poll", pollJSON("denied"))
        bots.script("github.oauth.poll", pollJSON("pending"))
        let github = model(bots)
        await github.refresh()
        await github.beginSignIn()
        await github.pollTask?.value
        await github.beginSignIn()
        #expect(bots.calls(to: "github.oauth.start").count == 2)
        guard case .code(let code) = github.signIn else { Issue.record("no code"); return }
        #expect(code.sessionID == "s2")
        await github.closeSignIn()
    }

    @Test("closing the sheet cancels the session and drops the code")
    func closeCancels() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON(session: "s9"))
        bots.script("github.oauth.poll", pollJSON("pending"))
        bots.script("github.oauth.cancel", ["ok": true])
        let github = GitHubTokenModel(client: GitHubTokenClient(gateway: bots.gateway), surfaces: scratchSurfaces()) { _ in
            try await Task.sleep(for: .seconds(60))
        }
        await github.refresh()
        await github.beginSignIn()
        guard case .code = github.signIn else { Issue.record("no code"); return }
        await github.closeSignIn()
        #expect(github.signIn == nil)
        #expect(bots.calls(to: "github.oauth.cancel").map { $0.params["session_id"] } == ["s9"])
        #expect(bots.calls(to: "github.oauth.poll").isEmpty)
    }

    @Test("repeated poll failures end the flow with a retry message")
    func pollFailures() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON())
        bots.script("github.oauth.poll") { _ in throw ScriptedBots.ScriptError.unscripted("poll") }
        let github = model(bots)
        await github.refresh()
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(github.signIn == .failed("We couldn't check your sign-in. Please try again."))
        #expect(bots.calls(to: "github.oauth.poll").count == 3)
    }

    @Test("a start failure shows a retry message; older gateways move to unsupported")
    func startFailures() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start") { _ in throw ScriptedBots.ScriptError.unscripted("start") }
        let github = model(bots)
        await github.refresh()
        await github.beginSignIn()
        #expect(github.signIn == .failed("We couldn't start sign-in. Please try again."))
        let old = ScriptedBots()
        old.script("github.token.status", statusJSON("missing"))
        old.script("github.oauth.start") { _ in throw methodNotFound }
        let other = model(old)
        await other.refresh()
        await other.beginSignIn()
        #expect(other.phase == .unsupported)
        #expect(other.signIn == nil)
    }

    @Test("saving a client ID sends it, then refreshes")
    func clientID() async throws {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("oauth_app_not_configured"))
        bots.script("github.oauth.set_client_id", ["ok": true])
        bots.script("github.token.status", statusJSON("missing"))
        let github = model(bots)
        await github.refresh()
        await github.saveClientID("  Iv1.abc123  ")
        #expect(bots.calls(to: "github.oauth.set_client_id").first?.params == ["client_id": "Iv1.abc123"])
        #expect(github.clientIDState == .saved)
        #expect(github.needsClientID == false)
        #expect(github.headline == "Not signed in")
    }

    @Test("a blank or failing client ID save shows failed and changes nothing")
    func clientIDFailure() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("oauth_app_not_configured"))
        bots.script("github.oauth.set_client_id") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let github = model(bots)
        await github.refresh()
        await github.saveClientID("   ")
        #expect(github.clientIDState == .failed)
        #expect(bots.calls(to: "github.oauth.set_client_id").isEmpty)
        await github.saveClientID("abc")
        #expect(github.clientIDState == .failed)
        #expect(github.needsClientID)
    }

    @Test("the code is not logged or described by the model once the sheet closes")
    func codeNotKept() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.oauth.start", startJSON())
        bots.script("github.oauth.poll", pollJSON("denied"))
        let github = model(bots)
        await github.refresh()
        await github.beginSignIn()
        await github.pollTask?.value
        await github.closeSignIn()
        #expect(!String(reflecting: github.signIn as Any).contains("ABCD-1234"))
        #expect(!String(reflecting: github.phase).contains("ABCD-1234"))
    }
}
