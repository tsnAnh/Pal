import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func statusJSON(_ state: String, login: String? = nil, scopes: [String] = [], missing: [String] = [], expires: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "state": .string(state), "scopes": .array(scopes.map { .string($0) }), "missing_scopes": .array(missing.map { .string($0) }),
        "token_kind": "classic", "git_protocol": "https",
    ]
    if let login { object["login"] = .string(login) }
    if let expires { object["expires_at"] = .string(expires) }
    return .object(object)
}

private func rpcFailure(_ code: Int, data: JSONValue? = nil) -> GatewayTransportError {
    .rpc(RPCError(code: code, message: "failed", data: data))
}

@MainActor
private func model(_ bots: ScriptedBots) -> GitHubTokenModel {
    GitHubTokenModel(client: GitHubTokenClient(gateway: bots.gateway))
}

@Suite("GitHub token")
@MainActor
struct GitHubTokenTests {
    @Test("every state maps to its row text")
    func stateText() {
        #expect(GitHubTokenStatus(statusJSON("set", login: "octo")).headline == "Set, signed in as octo")
        #expect(GitHubTokenStatus(statusJSON("set")).headline == "Set")
        #expect(GitHubTokenStatus(statusJSON("missing")).headline == "Missing")
        #expect(GitHubTokenStatus(statusJSON("invalid")).headline == "Invalid")
        #expect(GitHubTokenStatus(statusJSON("expired")).headline == "Expired")
        #expect(GitHubTokenStatus(statusJSON("missing_scopes", missing: ["workflow"])).headline == "Missing scopes: workflow")
        #expect(GitHubTokenStatus(statusJSON("missing_scopes")).headline == "Missing scopes")
        #expect(GitHubTokenStatus(statusJSON("unknown")).headline == "Unknown")
    }

    @Test("scopes and expiry show as detail only when the gateway returns them")
    func detail() {
        let full = GitHubTokenStatus(statusJSON("set", login: "octo", scopes: ["repo", "workflow"], expires: "2030-01-02T03:04:05Z"))
        #expect(full.scopes == ["repo", "workflow"])
        #expect(full.expiresAt == Date(timeIntervalSince1970: 1_893_553_445))
        #expect(full.detail?.hasPrefix("Scopes: repo, workflow\nExpires ") == true)
        #expect(GitHubTokenStatus(statusJSON("set", login: "octo")).detail == nil)
        let fractional = GitHubTokenStatus(statusJSON("set", expires: "2030-01-02T03:04:05.250Z"))
        #expect(fractional.expiresAt != nil)
    }

    @Test("unknown fields are ignored and unreadable ones become unknown, never a guess")
    func tolerantDecoding() {
        let odd = GitHubTokenStatus(["state": "from_the_future", "login": 7, "scopes": "repo", "expires_at": "soon", "extra": true])
        #expect(odd.state == .unknown)
        #expect(odd.login == nil)
        #expect(odd.scopes.isEmpty)
        #expect(odd.expiresAt == nil)
        #expect(odd.headline == "Unknown")
        #expect(GitHubTokenStatus(JSONValue.null).state == .unknown)
        #expect(GitHubTokenStatus(["state": "set", "login": "  "]).login == nil)
    }

    @Test("refresh reads github.token.status")
    func refresh() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("set", login: "octo"))
        let token = model(bots)
        #expect(token.headline == "Checking…")
        await token.refresh()
        #expect(token.status?.login == "octo")
        #expect(token.headline == "Set, signed in as octo")
        #expect(bots.calls(to: "github.token.status").count == 1)
    }

    @Test("method-not-found shows the unsupported state and blocks Set")
    func methodNotFound() async {
        let bots = ScriptedBots()
        bots.script("github.token.status") { _ in throw rpcFailure(-32601) }
        let token = model(bots)
        await token.refresh()
        #expect(token.phase == .unsupported)
        #expect(token.footnote == "This gateway does not support this yet.")
        #expect(!token.canSet)
    }

    @Test("a failing check shows unknown, and keeps the last good state")
    func unavailable() async {
        let bots = ScriptedBots()
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.token.status") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let token = model(bots)
        await token.refresh()
        await token.refresh()
        #expect(token.status?.state == .missing)
        let fresh = ScriptedBots()
        fresh.script("github.token.status") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let other = model(fresh)
        await other.refresh()
        #expect(other.phase == .unavailable)
        #expect(other.headline == "Unknown")
        #expect(other.canSet)
    }

    @Test("set sends the value once, returns the new status and never keeps the token")
    func setToken() async throws {
        let bots = ScriptedBots()
        let canary = "CANARY-\(UUID().uuidString)"
        bots.script("github.token.status", statusJSON("missing"))
        bots.script("github.token.set", statusJSON("set", login: "octo", scopes: ["repo", "workflow"]))
        let token = model(bots)
        await token.refresh()
        await token.set(SecretString(canary))
        let call = try #require(bots.calls(to: "github.token.set").first)
        #expect(call.params == ["value": .string(canary)])
        #expect(token.setState == .saved)
        #expect(token.status?.login == "octo")
        #expect(!String(describing: token).contains(canary))
        #expect(!String(reflecting: token.phase).contains(canary))
        #expect(!String(describing: token.setState).contains(canary))
        #expect(!Mirror(reflecting: token).children.contains { String(describing: $0.value).contains(canary) })
    }

    @Test("typed errors map to plain messages and keep the old state")
    func typedErrors() async {
        let cases: [(JSONValue, String)] = [
            (["code": "invalid"], "GitHub did not accept this token."),
            (["code": "expired"], "This token has expired. Create a new one."),
            (["code": "missing_scopes", "missing_scopes": ["workflow"]], "The token needs repo and workflow; missing: workflow."),
            (["code": "unreachable"], "Couldn't reach GitHub. Check the connection and try again."),
            (["code": "apply_failed"], "The token was accepted but couldn't be saved on this machine."),
        ]
        for (data, expected) in cases {
            let bots = ScriptedBots()
            bots.script("github.token.status", statusJSON("set", login: "octo"))
            bots.script("github.token.set") { _ in throw rpcFailure(-32000, data: data) }
            let token = model(bots)
            await token.refresh()
            await token.set(SecretString("x"))
            guard case .failed(let message) = token.setState else { Issue.record("not failed: \(expected)"); continue }
            #expect(message == expected + " Your current token was not changed.")
            #expect(token.status?.login == "octo")
        }
    }

    @Test("a typed error returned in the result is the same as one raised")
    func typedErrorInResult() async {
        let bots = ScriptedBots()
        bots.script("github.token.set", ["error": ["code": "missing_scopes", "message": "no", "missing_scopes": ["repo", "workflow"]]])
        let token = model(bots)
        await token.set(SecretString("x"))
        #expect(token.setState == .failed("The token needs repo and workflow; missing: repo, workflow. Your current token was not changed."))
        #expect(token.phase == .loading)
    }

    @Test("an unknown failure code is a generic, safe message")
    func unknownFailure() async {
        let bots = ScriptedBots()
        bots.script("github.token.set") { _ in throw rpcFailure(-32000, data: ["code": "from_the_future"]) }
        let token = model(bots)
        await token.set(SecretString("x"))
        #expect(token.setState == .failed("Couldn't save the token. Try again. Your current token was not changed."))
    }

    @Test("set on an older gateway moves to the unsupported state")
    func setUnsupported() async {
        let bots = ScriptedBots()
        bots.script("github.token.set") { _ in throw rpcFailure(-32601) }
        let token = model(bots)
        await token.set(SecretString("x"))
        #expect(token.phase == .unsupported)
        #expect(token.setState == .failed("This gateway does not support this yet."))
    }
}
