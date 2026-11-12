import Foundation
import Synchronization
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func statusJSON(signedIn: Bool = true, login: String? = "octo", proto: String = "https", problems: [JSONValue] = []) -> JSONValue {
    var object: [String: JSONValue] = [
        "signed_in": .bool(signedIn), "host": "box", "git_protocol": .string(proto), "ssh_host_key_known": .bool(true),
        "problems": .array(problems),
    ]
    if let login { object["login"] = .string(login) }
    return .object(object)
}

private func problem(_ id: String, fix: String, message: String = "gateway text") -> JSONValue {
    ["id": .string(id), "message": .string(message), "fix": .string(fix)]
}

private func startJSON(session: String = "s1", uri: String = "https://github.com/login/device", interval: Int = 5, expires: Int = 900) -> JSONValue {
    ["session_id": .string(session), "user_code": "ABCD-1234", "verification_uri": .string(uri), "expires_in": .int(expires), "interval": .int(interval)]
}

private func pollJSON(_ state: String, login: String? = nil, message: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["state": .string(state)]
    if let login { object["login"] = .string(login) }
    if let message { object["message"] = .string(message) }
    return .object(object)
}

private final class Sleeps: Sendable {
    private let log = Mutex<[Duration]>([])
    var recorded: [Duration] { log.withLock { $0 } }
    var sleep: @Sendable (Duration) async throws -> Void { { [self] duration in log.withLock { $0.append(duration) } } }
}

@MainActor
private func model(_ bots: ScriptedBots, sleeps: Sleeps = Sleeps()) -> GitHubAccountModel {
    GitHubAccountModel(client: GitHubClient(gateway: bots.gateway), sleep: sleeps.sleep)
}

private let rpcMethodNotFound = GatewayTransportError.rpc(RPCError(code: -32601, message: "method not found"))

@Suite("GitHub account")
@MainActor
struct GitHubAccountTests {
    @Test("status decodes the contract")
    func decodesStatus() async {
        let bots = ScriptedBots()
        bots.script("github.status", statusJSON(problems: [problem("git_ssh_unknown_host", fix: "github.git_protocol.fix")]))
        let github = model(bots)
        await github.refresh()
        guard case .ready(let status) = github.phase else { Issue.record("not ready"); return }
        #expect(status.accountLine == "Signed in as octo")
        #expect(status.gitProtocol == .https)
        #expect(status.problems.map(\.fix) == [.gitProtocol])
        #expect(status.problems.first?.message == "Downloads from GitHub over SSH may fail on this host. Switch to HTTPS.")
    }

    @Test("missing and unknown fields become unknown, never a guess")
    func toleratesBadFields() async {
        let bots = ScriptedBots()
        bots.script("github.status", ["git_protocol": "gopher", "extra": 1, "problems": [["id": "from_the_future", "fix": "do.something"]]])
        let github = model(bots)
        await github.refresh()
        guard case .ready(let status) = github.phase else { Issue.record("not ready"); return }
        #expect(status.signedIn == nil)
        #expect(status.accountLine == "Unknown")
        #expect(status.gitProtocol == .unknown)
        #expect(status.problems.count == 1)
        #expect(status.problems[0].fix == nil)
        #expect(status.problems[0].message == "GitHub reported a problem on this host.")
    }

    @Test("an older gateway shows the unsupported state, a failing one shows unavailable")
    func methodNotFound() async {
        let bots = ScriptedBots()
        bots.script("github.status") { _ in throw rpcMethodNotFound }
        let github = model(bots)
        await github.refresh()
        #expect(github.phase == .unsupported)
        let broken = ScriptedBots()
        broken.script("github.status") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let other = model(broken)
        await other.refresh()
        #expect(other.phase == .unavailable)
    }

    @Test("signed-out problem maps to the sign-in action")
    func signedOutAction() async {
        let bots = ScriptedBots()
        bots.script("github.status", statusJSON(signedIn: false, login: nil, proto: "unset", problems: [problem("gh_signed_out", fix: "github.signin")]))
        let github = model(bots)
        await github.refresh()
        #expect(github.problems.map(\.fix) == [.signIn])
        #expect(github.problems.first?.message == "GitHub is not signed in. Bots can't open pull requests until you sign in.")
    }

    @Test("sign-in polls at the interval, then refreshes the status")
    func signInSucceeds() async {
        let bots = ScriptedBots()
        let sleeps = Sleeps()
        bots.script("github.signin.start", startJSON(interval: 3))
        bots.script("github.signin.poll", pollJSON("pending"))
        bots.script("github.signin.poll", pollJSON("signed_in", login: "octo"))
        bots.script("github.status", statusJSON())
        let github = model(bots, sleeps: sleeps)
        await github.beginSignIn()
        guard case .code(let code) = github.signIn else { Issue.record("no code"); return }
        #expect(code.userCode == "ABCD-1234")
        await github.pollTask?.value
        #expect(github.signIn == .signedIn(login: "octo"))
        #expect(sleeps.recorded == [.seconds(3), .seconds(3)])
        #expect(bots.calls(to: "github.status").count == 1)
        guard case .ready(let status) = github.phase else { Issue.record("not refreshed"); return }
        #expect(status.login == "octo")
    }

    @Test("expired and failed end the sheet with a retry that starts a new session")
    func expiredFailedRetry() async {
        let bots = ScriptedBots()
        bots.script("github.signin.start", startJSON(session: "s1"))
        bots.script("github.signin.start", startJSON(session: "s2"))
        bots.script("github.signin.poll", pollJSON("expired"))
        bots.script("github.signin.poll", pollJSON("failed", message: "Access was denied."))
        let github = model(bots)
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(github.signIn == .expired)
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(github.signIn == .failed("Access was denied."))
        #expect(bots.calls(to: "github.signin.start").count == 2)
        #expect(bots.calls(to: "github.signin.poll").map { $0.params["session_id"] } == ["s1", "s2"])
    }

    @Test("closing the sheet cancels the session and drops the code")
    func closeCancels() async {
        let bots = ScriptedBots()
        bots.script("github.signin.start", startJSON(session: "s9"))
        bots.script("github.signin.cancel", ["ok": true])
        let github = GitHubAccountModel(client: GitHubClient(gateway: bots.gateway), sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        await github.beginSignIn()
        await github.closeSignIn()
        #expect(github.signIn == nil)
        #expect(bots.calls(to: "github.signin.cancel").map { $0.params["session_id"] } == ["s9"])
        #expect(bots.calls(to: "github.signin.poll").isEmpty)
    }

    @Test("a start that cannot be trusted fails without a code")
    func untrustedStart() async {
        let bots = ScriptedBots()
        bots.script("github.signin.start", startJSON(uri: "http://github.com/login/device"))
        let github = model(bots)
        await github.beginSignIn()
        #expect(github.signIn == .failed(GitHubAccountModel.startFailure))
    }

    @Test("repeated poll errors stop the sheet instead of spinning")
    func pollErrorsStop() async {
        let bots = ScriptedBots()
        bots.script("github.signin.start", startJSON())
        bots.script("github.signin.poll") { _ in throw ScriptedBots.ScriptError.unscripted("poll") }
        let github = model(bots)
        await github.beginSignIn()
        await github.pollTask?.value
        #expect(github.signIn == .failed(GitHubAccountModel.checkFailure))
        #expect(bots.calls(to: "github.signin.poll").count == GitHubAccountModel.maxPollFailures)
    }

    @Test("the git protocol fix saves and replaces the status, or fails and keeps it")
    func fixRefresh() async {
        let bots = ScriptedBots()
        bots.script("github.status", statusJSON(proto: "ssh", problems: [problem("git_ssh_unknown_host", fix: "github.git_protocol.fix")]))
        bots.script("github.git_protocol.fix", statusJSON(proto: "https"))
        let github = model(bots)
        await github.refresh()
        await github.perform(.gitProtocol)
        #expect(github.fix == .saved)
        #expect(github.problems.isEmpty)

        let failing = ScriptedBots()
        failing.script("github.status", statusJSON(proto: "ssh", problems: [problem("git_ssh_unknown_host", fix: "github.git_protocol.fix")]))
        failing.script("github.git_protocol.fix") { _ in throw ScriptedBots.ScriptError.unscripted("fix") }
        let other = model(failing)
        await other.refresh()
        await other.perform(.gitProtocol)
        #expect(other.fix == .failed)
        #expect(other.problems.count == 1)
    }
}
