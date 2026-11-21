import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Testing

private let figmaRedirect = "http://localhost:27890/callback"

private func figma(accounts: [ConnectorAccount]) -> ConnectApp {
    let entry = PalCatalogEntry(
        slug: "figma", name: "Figma", category: "Design", method: .oauthClient, verified: true,
        mcpURL: URL(string: "https://mcp.figma.com/mcp"), status: .connected, multiAccount: true, accounts: accounts
    )
    return ConnectCatalog.make(catalog: [entry], mcp: []).apps[0]
}

private func figmaEntry(_ app: ConnectApp) throws -> PalCatalogEntry {
    guard case .catalog(let entry) = app.source else { throw ConnectAppsError.failed }
    return entry
}

private func gateway(connect: CustomRPC.Reply? = nil) -> CustomRPC {
    CustomRPC([
        "connectors.oauth_client.setup": { _ in
            ["slug": "figma", "configured": true, "console_url": "https://console.example.test/apps", "redirect_url": .string(figmaRedirect)]
        },
        "connectors.oauth_client.connect": connect ?? { params in
            let encoded = (params["client_redirect_uri"]?.stringValue ?? figmaRedirect).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "https://www.figma.com/oauth?response_type=code&state=st-1&redirect_uri=\(encoded)"
            return ["slug": "figma", "auth_url": .string(link), "session_id": "s1"]
        },
        "connectors.oauth_client.remove": { _ in ["slug": "figma", "removed": true] },
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { _ in ["status": "approved"] },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

private let defaultOnly = [ConnectorAccount(name: "default", state: .connected)]

@Suite("Connector accounts on the client-registered sign-in")
struct ConnectorAccountOAuthClientTests {
    @Test func aSecondAccountStartsTheSignInWithItsNameAndCreateAndPollsItByName() async throws {
        let rpc = gateway()
        let app = figma(accounts: defaultOnly)
        let target = ConnectorAccountTarget.adding("work", to: app)
        let outcome = try await customService(rpc).connectOAuthClient(try figmaEntry(app), route: .pasteAddress, account: target)
        guard case .paste(let session) = outcome else { Issue.record("expected a paste session"); return }
        #expect(await session.submit("\(figmaRedirect)?code=abc&state=st-1") == .signedIn)
        let started = try #require(rpc.params("connectors.oauth_client.connect").first)
        #expect(started["account"]?.stringValue == "work" && started["create"]?.boolValue == true)
        #expect(rpc.params("mcp.servers.oauth.callback").first?["account"]?.stringValue == "work")
        #expect(rpc.params("mcp.servers.oauth.poll").first?["account"]?.stringValue == "work")
    }

    @Test func theFirstSignInSendsNoAccount() async throws {
        let rpc = gateway()
        let app = figma(accounts: [])
        _ = try await customService(rpc).connectOAuthClient(try figmaEntry(app), route: .pasteAddress)
        let started = try #require(rpc.params("connectors.oauth_client.connect").first)
        #expect(started["account"] == nil && started["create"] == nil)
    }

    @Test func aTakenNameIsATypedNameProblemNotASetupProblem() async throws {
        let rpc = gateway(connect: rpcFailure(4090, reason: "ALIAS_TAKEN", message: "already exists"))
        let app = figma(accounts: defaultOnly)
        let target = ConnectorAccountTarget.adding("work", to: app)
        await #expect(throws: ConnectAppsError.accountName(.taken)) {
            _ = try await customService(rpc).connectOAuthClient(try figmaEntry(app), route: .pasteAddress, account: target)
        }
    }

    @Test func disconnectingOneAccountRemovesThatAccountThroughTheClientVerb() async throws {
        let rpc = gateway()
        try await customService(rpc).disconnect(figma(accounts: defaultOnly + [ConnectorAccount(name: "work", state: .connected)]), account: "work")
        let removed = try #require(rpc.params("connectors.oauth_client.remove").first)
        #expect(removed["slug"]?.stringValue == "figma" && removed["account"]?.stringValue == "work")
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func disconnectingTheConnectorNamesNoAccount() async throws {
        let rpc = gateway()
        try await customService(rpc).disconnect(figma(accounts: defaultOnly))
        #expect(rpc.params("connectors.oauth_client.remove").first?["account"] == nil)
    }
}
