import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Testing

private func shopifyGateway(
    add: CustomRPC.Reply? = nil, update: CustomRPC.Reply? = nil, test: @escaping CustomRPC.Reply
) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": add ?? { _ in ["ok": true] },
        "mcp.servers.update": update ?? { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.test": test,
    ])
}

private func failedTest(reason: String, oauthNeeded: Bool = false) -> CustomRPC.Reply {
    { _ in ["ok": false, "reason": .string(reason), "oauth_needed": .bool(oauthNeeded), "oauth_tokens_present": false] }
}

private func thrown(_ work: () async throws -> Void) async -> (any Error)? {
    do { try await work(); return nil } catch { return error }
}

@Suite("Shopify store address")
struct ShopifyAddressTests {
    @Test(arguments: [
        ("acme", "https://acme.myshopify.com/api/mcp"),
        ("  Acme  ", "https://acme.myshopify.com/api/mcp"),
        ("acme.myshopify.com", "https://acme.myshopify.com/api/mcp"),
        ("ACME.MyShopify.com", "https://acme.myshopify.com/api/mcp"),
        ("https://acme.myshopify.com", "https://acme.myshopify.com/api/mcp"),
        ("https://acme.myshopify.com/", "https://acme.myshopify.com/api/mcp"),
        ("HTTPS://acme.myshopify.com/api/mcp", "https://acme.myshopify.com/api/mcp"),
        ("https://acme.myshopify.com/api/mcp/", "https://acme.myshopify.com/api/mcp"),
        ("shop.example.com", "https://shop.example.com/api/mcp"),
        ("https://shop.example.co.uk/", "https://shop.example.co.uk/api/mcp"),
        ("acme.myshopify.com.", "https://acme.myshopify.com/api/mcp"),
        ("my-store-2", "https://my-store-2.myshopify.com/api/mcp"),
    ])
    func acceptedAddressesBecomeTheStorefrontEndpoint(input: String, expected: String) throws {
        #expect(try ShopifyConnector.mcpURL(fromInput: input) == expected)
    }

    @Test(arguments: [
        ("", ShopifyAddressError.empty),
        ("   ", .empty),
        ("http://acme.myshopify.com", .notSecure),
        ("ftp://acme.myshopify.com", .notSecure),
        ("https://user@acme.myshopify.com", .credentials),
        ("https://user:pw@acme.myshopify.com", .credentials),
        ("acme.myshopify.com:8443", .port),
        ("https://acme.myshopify.com:443", .port),
        ("acme.myshopify.com/products", .wrongPath),
        ("https://acme.myshopify.com/api/mcp/extra", .wrongPath),
        ("acme.myshopify.com?x=1", .wrongPath),
        ("acme.myshopify.com#top", .wrongPath),
        ("https://", .invalid),
        ("my_store", .invalid),
        ("-acme", .invalid),
        ("acme-", .invalid),
        ("acme store", .invalid),
        ("store..myshopify.com", .invalid),
        ("100.64.0.5", .invalid),
        ("example.123", .invalid),
        ("[::1]", .invalid),
        (String(repeating: "a", count: 64), .invalid),
    ])
    func rejectedAddressesNameTheirProblem(input: String, expected: ShopifyAddressError) {
        #expect(throws: expected) { try ShopifyConnector.mcpURL(fromInput: input) }
    }

    @Test func everyProblemHasPlainWordsWithNoInternals() {
        let all: [ShopifyAddressError] = [.empty, .invalid, .notSecure, .credentials, .port, .wrongPath]
        for error in all {
            #expect(!error.message.isEmpty)
            for word in ["MCP", "endpoint", "api/mcp", "URL", "host"] { #expect(!error.message.contains(word), "\(error): \(word)") }
        }
    }
}

@Suite("Shopify flow")
struct ShopifyFlowTests {
    private func status(_ error: (any Error)?) -> SetupStatus? { error.map { ShopifyFlow.classify($0) } }

    @Test func theWizardIsOneAddressStepThenDone() throws {
        let steps = ShopifyFlow.steps()
        #expect(steps.map(\.id) == ["address", "done"])
        #expect(steps[0].fields == [SetupField(id: "address", label: "Store address", secret: false)])
        #expect(steps[0].primaryTitle == "Connect store")
        var engine = try #require(ShopifyFlow.engine())
        #expect(engine.current.id == "address" && !engine.isPrimaryEnabled)
        engine.setValue("acme", for: "address")
        #expect(engine.isPrimaryEnabled)
    }

    @Test func aReachableStoreIsSavedWithItsEndpointThenTestedAndNothingIsRemoved() async throws {
        let rpc = shopifyGateway(test: okTools(["search_shop_policies_and_faqs"]))
        try await customService(rpc).connectShopify("Acme")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test"])
        let add = try #require(rpc.params("mcp.servers.add").first)
        #expect(add["name"]?.stringValue == "shopify")
        #expect(add["config"]?["url"]?.stringValue == "https://acme.myshopify.com/api/mcp")
        #expect(add["config"]?["transport"]?.stringValue == "http")
        #expect(add["config"]?["auth"] == nil && add["bearer_token"] == nil)
    }

    @Test func aBadAddressNeverReachesTheGateway() async {
        let rpc = shopifyGateway(test: okTools(["a"]))
        let error = await thrown { try await customService(rpc).connectShopify("http://acme.myshopify.com") }
        #expect(error as? ShopifyAddressError == .notSecure)
        #expect(rpc.methods().isEmpty)
        #expect(status(error)?.kind == .vendorRefusedValue)
        #expect(status(error)?.reason == ShopifyAddressError.notSecure.message)
    }

    @Test func anUnreachableStoreIsRemovedAgainAndReportedAsUnreachable() async {
        let rpc = shopifyGateway(test: failedTest(reason: "unreachable"))
        let error = await thrown { try await customService(rpc).connectShopify("acme") }
        #expect(status(error)?.kind == .serverUnreachable)
        #expect(status(error)?.title == "Pal could not reach Shopify")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test", "mcp.servers.remove"])
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "shopify")
    }

    @Test func aWebsiteThatIsNotAStorefrontServerIsRemovedAgain() async {
        let rpc = shopifyGateway(test: failedTest(reason: "not_mcp"))
        let error = await thrown { try await customService(rpc).connectShopify("shop.example.com") }
        #expect(status(error)?.kind == .notMcpServer)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func anAddressThatAsksForSignInIsNotAStorefrontServerEither() async {
        let rpc = shopifyGateway(test: { _ in oauthChallenge() })
        let error = await thrown { try await customService(rpc).connectShopify("shop.example.com") }
        #expect(status(error)?.kind == .notMcpServer)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aBrokenConnectionToYourPalIsOfflineAndTheServerIsRemoved() async {
        let rpc = shopifyGateway(test: { _ in throw GatewayTransportError.timedOut })
        let error = await thrown { try await customService(rpc).connectShopify("acme") }
        #expect(status(error)?.kind == .offline)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aRefusedAddRemovesNothingBecauseNothingWasAdded() async {
        let rpc = shopifyGateway(add: rpcFailure(4030, reason: "forbidden"), test: okTools(["a"]))
        let error = await thrown { try await customService(rpc).connectShopify("acme") }
        #expect(status(error)?.kind == .forbidden)
        #expect(rpc.methods() == ["mcp.servers.add"])
    }

    @Test func anExistingServerIsUpdatedWithTheNewStoreAndNeverRemovedWhenTheCheckFails() async throws {
        let rpc = shopifyGateway(add: rpcFailure(4090), test: failedTest(reason: "unreachable"))
        let error = await thrown { try await customService(rpc).connectShopify("other-store") }
        #expect(status(error)?.kind == .serverUnreachable)
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.update", "mcp.servers.test"])
        let update = try #require(rpc.params("mcp.servers.update").first)
        #expect(update["config"]?["url"]?.stringValue == "https://other-store.myshopify.com/api/mcp")
    }
}

@Suite("Shopify row")
struct ShopifyRowTests {
    private func shopify(status: PalCatalogEntry.Status = .notConnected) throws -> ConnectApp {
        let row: JSONValue = [
            "slug": "shopify", "name": "Shopify", "category": "Sales and support", "method": "none", "verified": true,
            "status": .string(status.rawValue), "notes": "Needs your store address, like your-store.myshopify.com.",
        ]
        return ConnectCatalog.make(catalog: [try row.decoded(as: PalCatalogEntry.self)], mcp: []).apps[0]
    }

    @Test func theRowAsksForTheStoreAddressInsteadOfASignIn() throws {
        let app = try shopify()
        #expect(app.isShopify && !app.isT3Code)
        #expect(app.summary == "Needs your store address, like your-store.myshopify.com.")
        #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .connect)
    }

    @Test func aConnectedStoreIsConnected() throws {
        #expect(ConnectRowState.resolve(ConnectRowInput(app: try shopify(status: .connected))) == .connected)
    }

    @Test func aConnectorThatCannotBeUsedHereShowsItsOwnReasonNotTheGenericOne() throws {
        let row: JSONValue = [
            "slug": "posthog", "name": "PostHog", "category": "Monitoring and analytics", "method": "mcp_oauth", "verified": true,
            "status": "needs_setup", "mcp_url": "https://mcp.posthog.com/mcp",
            "notes": "This app needs your Pal's public web address. Set it up on your Pal first.",
        ]
        let app = ConnectCatalog.make(catalog: [try row.decoded(as: PalCatalogEntry.self)], mcp: []).apps[0]

        #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .unavailable)
        #expect(app.summary == "This app needs your Pal's public web address. Set it up on your Pal first.")
    }

    @Test func slackAndDiscordToolsUseTheOwnersClientSetupLikeTheOtherOauthClients() throws {
        for slug in ["slack_mcp", "discord_mcp"] {
            let row: JSONValue = [
                "slug": .string(slug), "name": "X", "category": "Communication", "method": "oauth_client", "verified": true,
                "status": "needs_setup", "mcp_url": "https://mcp.example.com/mcp",
            ]
            let app = ConnectCatalog.make(catalog: [try row.decoded(as: PalCatalogEntry.self)], mcp: []).apps[0]
            #expect(app.oauthClientEntry?.slug == slug)
            #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .setUp)
        }
    }
}
