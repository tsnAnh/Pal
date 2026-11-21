import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Testing

private let authURL = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Fcallback"
private let redirect = "http://127.0.0.1:50123/callback"

private func entry(
    _ slug: String = "notion", method: PalCatalogEntry.Method = .mcpOAuth, status: PalCatalogEntry.Status = .notConnected,
    accounts: [ConnectorAccount] = []
) -> PalCatalogEntry {
    PalCatalogEntry(
        slug: slug, name: slug.capitalized, category: "Docs", method: method, verified: true,
        mcpURL: URL(string: "https://mcp.example.com/mcp"), status: status, multiAccount: true, accounts: accounts
    )
}

private func app(_ entry: PalCatalogEntry) -> ConnectApp {
    ConnectCatalog.make(catalog: [entry], mcp: []).apps[0]
}

private let defaultOnly = [ConnectorAccount(name: "default", state: .connected)]

private func connectedApp(_ slug: String = "notion", method: PalCatalogEntry.Method = .mcpOAuth) -> ConnectApp {
    app(entry(slug, method: method, status: .connected, accounts: defaultOnly))
}

private func gateway(
    add: CustomRPC.Reply? = nil, start: CustomRPC.Reply? = nil, poll: JSONValue = ["status": "approved"], extra: [String: CustomRPC.Reply] = [:]
) -> CustomRPC {
    var replies: [String: CustomRPC.Reply] = [
        "mcp.servers.add": add ?? { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.update": { _ in ["ok": true] },
        "mcp.servers.set_api_key": { _ in ["ok": true] },
        "mcp.servers.oauth.start": start ?? { _ in ["session_id": "s1", "auth_url": .string(authURL)] },
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { _ in poll },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
        "mcp.servers.test": okTools(["search"]),
        "mcp.servers.accounts.rename": { _ in ["ok": true] },
    ]
    for (method, reply) in extra { replies[method] = reply }
    return CustomRPC(replies)
}

private let alreadyAdded: CustomRPC.Reply = { _ in throw GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")) }

private func paste(_ service: ConnectAppsService, _ app: ConnectApp, account: ConnectorAccountTarget?) async throws -> any McpPasteSigning {
    guard case .paste(let session) = try await service.signInMcp(app, platform: .iPhone, account: account) else { throw ConnectAppsError.failed }
    return session
}

@Suite("Connector account targets")
struct ConnectorAccountTargetTests {
    @Test func addingToAConnectorThatHasAccountsCreatesAndSelects() {
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        #expect(target == ConnectorAccountTarget(name: "work", create: true, selectsAccount: true))
    }

    @Test func addingTheFirstAccountCreatesWithoutSelecting() {
        let target = ConnectorAccountTarget.adding("default", to: app(entry()))
        #expect(target == ConnectorAccountTarget(name: "default", create: true, selectsAccount: false))
    }

    @Test func reconnectingTheOnlyAccountDoesNotSelect() {
        #expect(ConnectorAccountTarget.existing("default", in: connectedApp()) == ConnectorAccountTarget(name: "default", create: false, selectsAccount: false))
    }

    @Test func reconnectingOneOfSeveralSelects() {
        let two = app(entry(status: .connected, accounts: defaultOnly + [ConnectorAccount(name: "work", state: .needsReconnect)]))
        #expect(ConnectorAccountTarget.existing("work", in: two).selectsAccount)
        #expect(ConnectorAccountTarget.existing("default", in: two).selectsAccount)
    }
}

@Suite("Connector accounts on the service wire")
struct ConnectorAccountServiceTests {
    @Test func theFirstConnectSendsNoAccountAnywhere() async throws {
        let rpc = gateway()
        let session = try await paste(customService(rpc), app(entry()), account: nil)
        #expect(await session.submit("\(redirect)?code=abc&state=st-1") == .signedIn)
        for method in ["mcp.servers.add", "mcp.servers.oauth.start", "mcp.servers.oauth.callback", "mcp.servers.oauth.poll"] {
            for params in rpc.params(method) {
                #expect(params["account"] == nil)
                #expect(params["create"] == nil)
            }
        }
    }

    @Test func addingAnotherAccountCarriesItThroughEveryStep() async throws {
        let rpc = gateway(add: alreadyAdded)
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        let session = try await paste(customService(rpc), connectedApp(), account: target)
        #expect(await session.submit("\(redirect)?code=abc&state=st-1") == .signedIn)
        let start = try #require(rpc.params("mcp.servers.oauth.start").first)
        #expect(start["name"]?.stringValue == "notion")
        #expect(start["account"]?.stringValue == "work")
        #expect(start["create"]?.boolValue == true)
        let callback = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(callback["account"]?.stringValue == "work")
        #expect(callback["create"] == nil)
        let poll = try #require(rpc.params("mcp.servers.oauth.poll").first)
        #expect(poll["account"]?.stringValue == "work")
        #expect(poll["name"]?.stringValue == "notion")
    }

    @Test func reconnectingAnAccountSendsItWithoutCreate() async throws {
        let rpc = gateway(add: alreadyAdded)
        let target = ConnectorAccountTarget.existing("work", in: connectedApp())
        _ = try await paste(customService(rpc), connectedApp(), account: target)
        let start = try #require(rpc.params("mcp.servers.oauth.start").first)
        #expect(start["account"]?.stringValue == "work")
        #expect(start["create"] == nil)
    }

    @Test func cancellingASecondAccountSignInSendsTheAccountAndRemovesNothing() async throws {
        let rpc = gateway(add: alreadyAdded)
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        let session = try await paste(customService(rpc), connectedApp(), account: target)
        await session.cancel()
        let cancel = try #require(rpc.params("mcp.servers.oauth.cancel").first)
        #expect(cancel["account"]?.stringValue == "work")
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aFailedFirstSignInRemovesTheServerItAddedWithNoAccount() async throws {
        let rpc = gateway()
        let target = ConnectorAccountTarget.adding("default", to: app(entry()))
        let session = try await paste(customService(rpc), app(entry()), account: target)
        let outcome = await session.submit("\(redirect)?code=abc&state=other")
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        let removal = try #require(rpc.params("mcp.servers.remove").first)
        #expect(removal["name"]?.stringValue == "notion")
        #expect(removal["account"] == nil)
    }

    @Test func aFailedSecondSignInNeverRemovesTheServer() async throws {
        let rpc = gateway(add: alreadyAdded)
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        let session = try await paste(customService(rpc), connectedApp(), account: target)
        let outcome = await session.submit("\(redirect)?code=abc&state=other")
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aStartThatFailsForASecondAccountNeverRemovesTheServer() async {
        let rpc = gateway(add: alreadyAdded, start: rpcFailure(4001, message: "boom"))
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        await #expect(throws: (any Error).self) { _ = try await paste(customService(rpc), connectedApp(), account: target) }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aNameAlreadyInUseOnTheGatewayIsATypedNameProblem() async {
        let rpc = gateway(add: alreadyAdded, start: rpcFailure(4090, message: "account already exists"))
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        await #expect(throws: ConnectAppsError.accountName(.taken)) { _ = try await paste(customService(rpc), connectedApp(), account: target) }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func theMacLoopbackRouteCarriesTheAccountToo() async throws {
        let rpc = gateway(add: alreadyAdded, start: { params in
            let target = (params["client_redirect_uri"]?.stringValue ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return ["session_id": "s1", "auth_url": .string("https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=\(target)")]
        })
        let browser = AccountRedirectBrowser(code: "abc")
        let service = ConnectAppsService(
            rpc: rpc, profile: nil, browser: browser, timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
        )
        let target = ConnectorAccountTarget.adding("work", to: connectedApp())
        try await service.connect(connectedApp(), account: target)
        #expect(rpc.params("mcp.servers.oauth.start").first?["account"]?.stringValue == "work")
        #expect(rpc.params("mcp.servers.oauth.callback").first?["account"]?.stringValue == "work")
        #expect(rpc.params("mcp.servers.oauth.poll").first?["account"]?.stringValue == "work")
    }

    @Test func anApiKeyAccountStoresItsKeyThroughSetApiKeyWithTheAccount() async throws {
        let rpc = gateway(add: alreadyAdded)
        let github = connectedApp("github", method: .apiKey)
        let target = ConnectorAccountTarget.adding("work", to: github)
        try await customService(rpc).connect(github, credentials: ["token": "tok-work"], account: target)
        let sent = try #require(rpc.params("mcp.servers.set_api_key").first)
        #expect(sent["name"]?.stringValue == "github")
        #expect(sent["value"]?.stringValue == "tok-work")
        #expect(sent["account"]?.stringValue == "work")
        #expect(sent["create"]?.boolValue == true)
        #expect(sent["env_var"] == nil)
        #expect(!rpc.methods().contains("mcp.servers.update"))
    }

    @Test func aFirstApiKeyAccountAddsTheServerThenStoresTheKeyAndUndoesBothOnFailure() async throws {
        let rpc = gateway(extra: ["mcp.servers.set_api_key": rpcFailure(4063, message: "value is not a valid credential")])
        let github = app(entry("github", method: .apiKey))
        let target = ConnectorAccountTarget.adding("default", to: github)
        await #expect(throws: (any Error).self) {
            try await customService(rpc).connect(github, credentials: ["token": "tok"], account: target)
        }
        #expect(rpc.methods().first == "mcp.servers.add")
        #expect(rpc.params("mcp.servers.add").first?["bearer_token"] == nil)
        let removal = try #require(rpc.params("mcp.servers.remove").first)
        #expect(removal["account"] == nil)
    }

    @Test func aSecondApiKeyAccountThatFailsKeepsTheServer() async {
        let rpc = gateway(add: alreadyAdded, extra: ["mcp.servers.set_api_key": rpcFailure(4063, message: "bad")])
        let github = connectedApp("github", method: .apiKey)
        let target = ConnectorAccountTarget.adding("work", to: github)
        await #expect(throws: (any Error).self) {
            try await customService(rpc).connect(github, credentials: ["token": "tok"], account: target)
        }
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func theFirstApiKeyConnectWithoutAnAccountIsUnchanged() async throws {
        let rpc = gateway()
        let github = app(entry("github", method: .apiKey))
        try await customService(rpc).connect(github, credentials: ["token": "tok"])
        #expect(rpc.methods() == ["mcp.servers.add"])
        #expect(rpc.params("mcp.servers.add").first?["bearer_token"]?.stringValue == "tok")
    }

    @Test func aPresetKeyAccountSendsTheAccountAndLeavesTheVariableNameToTheGateway() async throws {
        let rpc = gateway(add: alreadyAdded)
        let preset = ConnectApp(
            id: "mcp:github", name: "GitHub", summary: "", category: "Other",
            source: .mcp(name: "github", requires: ["MCP_GITHUB_API_KEY"]), state: .connected
        )
        let target = ConnectorAccountTarget(name: "work", create: true, selectsAccount: true)
        try await customService(rpc).connect(preset, credentials: ["MCP_GITHUB_API_KEY": "k"], account: target)
        let sent = try #require(rpc.params("mcp.servers.set_api_key").first)
        #expect(sent["account"]?.stringValue == "work")
        #expect(sent["create"]?.boolValue == true)
        #expect(sent["env_var"] == nil)
    }

    @Test func disconnectingTheWholeConnectorSendsNoAccount() async throws {
        let rpc = gateway()
        try await customService(rpc).disconnect(connectedApp())
        let sent = try #require(rpc.params("mcp.servers.remove").first)
        #expect(sent["name"]?.stringValue == "notion")
        #expect(sent["account"] == nil)
    }

    @Test func disconnectingOneAccountSendsOnlyThatAccount() async throws {
        let rpc = gateway()
        try await customService(rpc).disconnect(connectedApp(), account: "work")
        let sent = try #require(rpc.params("mcp.servers.remove").first)
        #expect(sent["name"]?.stringValue == "notion")
        #expect(sent["account"]?.stringValue == "work")
    }

    @Test func aConnectionTestNamesTheAccount() async throws {
        let rpc = gateway()
        let github = connectedApp("github", method: .apiKey)
        let failure = await customService(rpc).tokenFailure(github, account: "work")
        #expect(failure == nil)
        let sent = try #require(rpc.params("mcp.servers.test").first)
        #expect(sent["name"]?.stringValue == "github")
        #expect(sent["account"]?.stringValue == "work")
        _ = await customService(rpc).tokenFailure(github)
        #expect(rpc.params("mcp.servers.test").last?["account"] == nil)
    }

    @Test func renameCallsTheNewVerbWithTheThreeNames() async throws {
        let rpc = gateway()
        let two = app(entry(status: .connected, accounts: defaultOnly + [ConnectorAccount(name: "work", state: .connected)]))
        try await customService(rpc).renameAccount(two, from: "work", to: "client")
        let sent = try #require(rpc.params("mcp.servers.accounts.rename").first)
        #expect(sent["name"]?.stringValue == "notion")
        #expect(sent["account"]?.stringValue == "work")
        #expect(sent["new_account"]?.stringValue == "client")
    }

    @Test(arguments: [("Client", ConnectorAccountNameError.invalidCharacter), ("", .empty), ("default", .taken), ("-x", .leadingHyphen)])
    func renameRefusesABadNameBeforeCallingTheGateway(_ name: String, _ problem: ConnectorAccountNameError) async {
        let rpc = gateway()
        let two = app(entry(status: .connected, accounts: defaultOnly + [ConnectorAccount(name: "work", state: .connected)]))
        await #expect(throws: ConnectAppsError.accountName(problem)) { try await customService(rpc).renameAccount(two, from: "work", to: name) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func renameToTheSameNameIsRefusedAsTaken() async {
        let rpc = gateway()
        let two = app(entry(status: .connected, accounts: defaultOnly + [ConnectorAccount(name: "work", state: .connected)]))
        await #expect(throws: ConnectAppsError.accountName(.taken)) { try await customService(rpc).renameAccount(two, from: "work", to: "work") }
    }

    @Test func aGatewayNameClashOnRenameIsATypedNameProblem() async {
        let rpc = gateway(extra: ["mcp.servers.accounts.rename": rpcFailure(4090, message: "account already exists")])
        let two = app(entry(status: .connected, accounts: defaultOnly + [ConnectorAccount(name: "work", state: .connected)]))
        await #expect(throws: ConnectAppsError.accountName(.taken)) { try await customService(rpc).renameAccount(two, from: "work", to: "client") }
    }
}

private struct AccountRedirectBrowser: AuthorizationBrowser {
    let code: String

    func present(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "redirect_uri" })?.value, var back = URLComponents(string: target) else { return }
        back.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: "st-1")]
        _ = try await URLSession.shared.data(from: back.url!)
        try await Task.sleep(for: .seconds(10))
    }

    func dismiss() async {}
}
