import Foundation
import PalConnect
import PalProtocol
import Testing

private let fakeSecret = "fake-token-do-not-use"

private func row(extra: [String: JSONValue] = [:]) -> JSONValue {
    var value: [String: JSONValue] = ["slug": "github", "name": "GitHub", "method": "api_key", "status": "not_connected"]
    for (key, item) in extra { value[key] = item }
    return .object(value)
}

private let tokenStep: JSONValue = [
    "id": "token", "kind": "paste", "title": "Paste your token", "body": "Paste the token.",
    "links": [], "copies": [],
    "fields": [["id": "token", "label": "Token", "secret": true, "prefixes": ["github_pat_", "ghp_"]]],
    "check": "github_token",
]

private func guided(_ steps: [JSONValue]) -> JSONValue {
    row(extra: ["setup_guide": ["steps": .array(steps)], "setup_progress": ["step_id": "token", "saved": []]])
}

@Suite("Setup guide wire")
struct SetupGuideWireTests {
    @Test func aRowWithoutAGuideStillDecodes() throws {
        let entry = try row().decoded(as: PalCatalogEntry.self)
        #expect(entry.setupGuide == nil && entry.setupProgress == nil)
        #expect(entry.slug == "github" && entry.method == .apiKey)
    }

    @Test func aGuideAndItsProgressDecodeOnTheRow() throws {
        let entry = try guided([tokenStep]).decoded(as: PalCatalogEntry.self)
        let step = try #require(entry.setupGuide?.steps.first)
        #expect(step.id == "token" && step.kind == .paste && step.check == .githubToken)
        #expect(step.fields == [SetupField(id: "token", label: "Token", secret: true, prefixes: ["github_pat_", "ghp_"])])
        #expect(entry.setupProgress == SetupProgress(stepID: "token", saved: []))
        #expect(entry.setupGuide?.index(of: entry.setupProgress?.stepID) == 0)
    }

    @Test func linksCopiesAndOptionalFieldsDecode() throws {
        let page: JSONValue = [
            "id": "console", "kind": "open_page", "title": "Open the console",
            "links": [["label": "Console", "url": "https://console.example.test/credentials"]],
            "copies": [["label": "Redirect URI", "value": "https://pal.example.test/callback"]],
        ]
        let guide = try #require(try guided([page, tokenStep]).decoded(as: PalCatalogEntry.self).setupGuide)
        let first = try #require(guide.steps.first)
        #expect(first.kind == .openPage && first.body == "" && first.check == nil && first.fields.isEmpty)
        #expect(first.links == [SetupLink(label: "Console", url: URL(string: "https://console.example.test/credentials")!)])
        #expect(first.copies == [SetupCopy(label: "Redirect URI", value: "https://pal.example.test/callback")])
        #expect(guide.index(of: "token") == 1 && guide.index(of: "missing") == 0 && guide.index(of: nil) == 0)
    }

    @Test func aLinkThatIsNotAWebAddressIsDroppedWithoutLosingTheStep() throws {
        let page: JSONValue = [
            "id": "console", "kind": "open_page", "title": "Open the console",
            "links": [["label": "Bad", "url": "file:///etc/passwd"], ["label": "Good", "url": "https://console.example.test/"]],
        ]
        let step = try #require(try guided([page]).decoded(as: PalCatalogEntry.self).setupGuide?.steps.first)
        #expect(step.links.map(\.label) == ["Good"])
    }

    @Test func anAddressProblemAndAFallbackDecodeOnTheirSteps() throws {
        let address: JSONValue = [
            "id": "address", "kind": "public_url", "title": "Address", "problem": "ip_host", "problem_host": "100.101.102.103",
        ]
        let console: JSONValue = [
            "id": "console", "kind": "open_page", "title": "Console",
            "fallback": [
                "label": "Google rejected the address", "body": "Use your own domain.",
                "links": [
                    ["label": "Desktop app guide", "url": "https://developers.google.com/identity/protocols/oauth2/native-app"],
                    ["label": "Bad", "url": "nope"],
                ],
            ],
        ]
        let guide = try #require(try guided([address, console]).decoded(as: PalCatalogEntry.self).setupGuide)
        let first = try #require(guide.addressStep)
        #expect(first.problem == .ipHost && first.problemHost == "100.101.102.103")
        #expect(first.problem?.details(host: first.problemHost) == "IP_HOST, host 100.101.102.103, rule: address must be a domain name, not an IP address")
        let fallback = try #require(guide.steps.last?.fallback)
        #expect(fallback.label == "Google rejected the address" && fallback.body == "Use your own domain.")
        #expect(fallback.links.map(\.label) == ["Desktop app guide"])
        #expect(guide.steps.last?.problem == nil && first.fallback == nil)
    }

    @Test func anUnknownProblemOrABrokenFallbackLeavesTheStepReadable() throws {
        let step: JSONValue = [
            "id": "address", "kind": "public_url", "title": "Address", "problem": "future_rule", "fallback": ["body": "no label"],
        ]
        let parsed = try #require(try guided([step]).decoded(as: PalCatalogEntry.self).setupGuide?.steps.first)
        #expect(parsed.problem == nil && parsed.fallback == nil && parsed.title == "Address")
    }

    @Test func theCanvaClientCheckKindDecodes() throws {
        let canva = JSONValue.object(tokenStep.objectValue!.merging(["check": "canva_client"]) { _, new in new })
        let step = try #require(try guided([canva]).decoded(as: PalCatalogEntry.self).setupGuide?.steps.first)
        #expect(step.check == .canvaClient && step.kind == .paste)
    }

    @Test func anUnknownCheckKindLeavesTheStepWithoutACheck() throws {
        var future = tokenStep
        future = .object(future.objectValue!.merging(["check": "future_check"]) { _, new in new })
        let step = try #require(try guided([future]).decoded(as: PalCatalogEntry.self).setupGuide?.steps.first)
        #expect(step.check == nil && step.kind == .paste)
    }

    @Test func aGuideTheAppCannotReadFallsBackToTheOldPathWithoutDroppingTheRow() throws {
        let future: JSONValue = ["id": "x", "kind": "hologram", "title": "Future"]
        let entry = try guided([future]).decoded(as: PalCatalogEntry.self)
        #expect(entry.setupGuide == nil)
        #expect(entry.slug == "github")
        let empty = try guided([]).decoded(as: PalCatalogEntry.self)
        #expect(empty.setupGuide == nil)
    }

    @Test func onlyACatalogRowWithAGuideOffersOne() throws {
        let source = ConnectAppSource.catalog(catalogEntry("a", "A", "", method: .apiKey))
        let plain = ConnectApp(id: "a", name: "A", summary: "", category: "", source: source, state: .disconnected)
        let entry = try guided([tokenStep]).decoded(as: PalCatalogEntry.self)
        let guidedApp = ConnectApp(id: "b", name: "B", summary: "", category: "", source: .catalog(entry), state: .disconnected)
        #expect(plain.setupGuideEntry == nil)
        #expect(guidedApp.setupGuideEntry?.slug == "github")
    }
}

@Suite("Setup field shape")
struct SetupFieldShapeTests {
    private let token = SetupField(id: "token", label: "Token", secret: true, prefixes: ["github_pat_", "ghp_"])
    private let clientID = SetupField(id: "client_id", label: "Client ID", suffix: ".apps.googleusercontent.com")
    private let secret = SetupField(id: "client_secret", label: "Client secret", secret: true)

    @Test func emptyAndBlankAreEmpty() {
        #expect(token.shape(of: "") == .empty)
        #expect(token.shape(of: "  \n ") == .empty)
    }

    @Test func aPrefixedFieldAcceptsEachListedPrefix() {
        #expect(token.shape(of: "github_pat_abc123").isValid)
        #expect(token.shape(of: "ghp_abc123").isValid)
        #expect(token.shape(of: "  ghp_abc123\n").isValid)
    }

    @Test func aWrongPrefixNamesWhatIsExpected() {
        #expect(token.shape(of: "abc123") == .wrongStart(["github_pat_", "ghp_"]))
        #expect(token.shape(of: "abc123").hint?.contains("github_pat_") == true)
        #expect(token.shape(of: "abc123").hint?.contains("ghp_") == true)
    }

    @Test func aSuffixedFieldNeedsItsSuffix() {
        #expect(clientID.shape(of: "123-abc.apps.googleusercontent.com").isValid)
        #expect(clientID.shape(of: "123-abc") == .wrongEnd(".apps.googleusercontent.com"))
        #expect(clientID.shape(of: "123-abc").hint?.contains(".apps.googleusercontent.com") == true)
    }

    @Test func spacesInsideAValueAreRejected() {
        #expect(secret.shape(of: "abc def") == .hasSpaces)
        #expect(token.shape(of: "ghp_abc def") == .hasSpaces)
    }

    @Test func aFieldWithNoConstraintsAcceptsAnyNonEmptyValueWithoutSpaces() {
        #expect(secret.shape(of: "GOCSPX-abc_123").isValid)
    }

    @Test func validAndEmptyShowNoHint() {
        #expect(SetupFieldShape.valid.hint == nil && SetupFieldShape.empty.hint == nil)
    }
}

private func ids() -> CallCounter { CallCounter() }

private func catalogRows() -> CustomRPC.Reply {
    { _ in ["connectors": [guided([tokenStep])]] }
}

private func step(check: SetupStep.Check?, fields: [SetupField]) -> SetupStep {
    SetupStep(id: "paste", kind: .paste, title: "Paste", fields: fields, check: check)
}

private let clientFields = [SetupField(id: "client_id", label: "Client ID"), SetupField(id: "client_secret", label: "Client secret", secret: true)]

@Suite("Setup check")
struct SetupCheckTests {
    private let google = catalogEntry("google-workspace", "Google Workspace", "Files and docs", method: .oauthClient, url: nil)
    private let github = catalogEntry("github", "GitHub", "Developer", method: .apiKey)

    @Test func catalogEntryFindsTheRowBySlug() async throws {
        let rpc = CustomRPC(["connectors.catalog": catalogRows()])
        let entry = try #require(try await customService(rpc).catalogEntry(slug: "github"))
        #expect(entry.setupGuide?.steps.count == 1)
        #expect(try await customService(rpc).catalogEntry(slug: "nope") == nil)
    }

    @Test func checkWritesEachValueToTheVaultThenSendsOnlyItemIdsAndKeepsThemOnSuccess() async throws {
        let issued = ids()
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": .string("item-\(issued.next())")] },
            "connectors.setup.check": { _ in ["slug": "google-workspace", "ok": true] },
            "connectors.oauth_client.save": { _ in ["slug": "google-workspace", "configured": true, "redirect_url": .null] },
        ])
        let service = customService(rpc, profile: "alpha")
        let values = ["client_id": "fake-id.apps.googleusercontent.com", "client_secret": fakeSecret]
        let verification = try await service.verifySetup(google, step: step(check: .googleClient, fields: clientFields), values: values)
        #expect(verification.result.ok)
        let sent = try #require(rpc.params("connectors.setup.check").first)
        #expect(sent["slug"]?.stringValue == "google-workspace" && sent["profile"]?.stringValue == "alpha")
        #expect(sent["values"]?["client_id"]?.stringValue == "item-1" && sent["values"]?["client_secret"]?.stringValue == "item-2")
        let wire = try #require(String(bytes: try JSONEncoder().encode(sent), encoding: .utf8))
        #expect(!wire.contains(fakeSecret))
        #expect(!rpc.methods().contains("vault.remove"))
        try await service.saveVerifiedClient(google, verification)
        let save = try #require(rpc.params("connectors.oauth_client.save").first)
        #expect(save["client_id_item"]?.stringValue == "item-1" && save["client_secret_item"]?.stringValue == "item-2")
        #expect(rpc.methods().filter { $0 == "vault.add" }.count == 2)
    }

    @Test func aRejectedCheckIsAResultAndRemovesTheStoredValues() async throws {
        let issued = ids()
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": .string("item-\(issued.next())")] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": { _ in ["slug": "github", "ok": false, "reason": "INVALID_TOKEN", "message": "Bad credentials"] },
        ])
        let verification = try await customService(rpc).verifySetup(
            github, step: step(check: .githubToken, fields: [SetupField(id: "token", label: "Token", secret: true)]), values: ["token": fakeSecret]
        )
        #expect(!verification.result.ok && verification.result.reason == "INVALID_TOKEN")
        #expect(rpc.params("vault.remove").compactMap { $0["id"]?.stringValue } == ["item-1"])
        let failure = verification.result.failure(appName: "GitHub")
        #expect(failure.code == "INVALID_TOKEN" && failure.reason == "GitHub didn't accept that token. Check it and paste it again.")
    }

    @Test func aGatewayErrorRemovesTheStoredValuesAndKeepsTheFault() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-1"] },
            "vault.remove": { _ in ["ok": true] },
            "connectors.setup.check": rpcFailure(4003, reason: "NOT_OWNER"),
        ])
        do {
            _ = try await customService(rpc).verifySetup(
                github, step: step(check: .githubToken, fields: [SetupField(id: "token", label: "Token", secret: true)]), values: ["token": fakeSecret]
            )
            Issue.record("expected a failure")
        } catch {
            let failure = error as? ConnectAppsError
            #expect(failure?.oauthClientFailure == .notOwner && failure?.fault != nil)
        }
        #expect(rpc.methods().contains("vault.remove"))
    }

    @Test func aStepWithoutACheckStoresTheValuesAndSkipsTheProviderCall() async throws {
        let rpc = CustomRPC(["vault.add": { _ in ["id": "item-x"] }])
        let verification = try await customService(rpc).verifySetup(
            google, step: step(check: nil, fields: clientFields), values: ["client_id": "a", "client_secret": "b"]
        )
        #expect(verification.result.ok)
        #expect(!rpc.methods().contains("connectors.setup.check"))
    }

    @Test func discardingAVerificationRemovesItsVaultItems() async throws {
        let rpc = CustomRPC([
            "vault.add": { _ in ["id": "item-t"] },
            "connectors.setup.check": { _ in ["slug": "github", "ok": true, "account": "octo"] },
            "vault.remove": { _ in ["ok": true] },
        ])
        let service = customService(rpc)
        let verification = try await service.verifySetup(
            github, step: step(check: .githubToken, fields: [SetupField(id: "token", label: "Token", secret: true)]), values: ["token": fakeSecret]
        )
        #expect(verification.result.account == "octo")
        await service.discardVerified(verification)
        #expect(rpc.params("vault.remove").compactMap { $0["id"]?.stringValue } == ["item-t"])
    }

    @Test func eachFailureReasonHasPlainProductText() {
        let reasons = ["INVALID_TOKEN", "INVALID_CLIENT", "CHECK_UNAVAILABLE"]
        for reason in reasons {
            let text = SetupCheckResult(slug: "x", ok: false, reason: reason).failure(appName: "Figma").reason
            #expect(text.contains("Figma") && !text.contains(reason))
        }
        let fallback = SetupCheckResult(slug: "x", ok: false, reason: nil, message: "Try later").failure(appName: "Figma")
        #expect(fallback.code == "CHECK_FAILED" && fallback.reason == "Try later")
    }
}

@Suite("Remove saved client")
struct RemoveSavedClientTests {
    @Test func removingTheClientAsksTheGatewayToDeleteItAndNotJustTheSignIn() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.remove": { _ in ["slug": "figma", "removed": true] }])
        try await customService(rpc, profile: "alpha").removeOAuthClient(slug: "figma")
        let sent = try #require(rpc.params("connectors.oauth_client.remove").first)
        #expect(sent["slug"]?.stringValue == "figma" && sent["remove_client"]?.boolValue == true && sent["profile"]?.stringValue == "alpha")
    }

    @Test func theSignInRollbackNeverDeletesTheClient() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.remove": { _ in ["slug": "figma", "removed": true] }])
        try await customService(rpc).removeOAuthClientSignIn(slug: "figma")
        #expect(rpc.params("connectors.oauth_client.remove").first?["remove_client"] == nil)
    }

    @Test func aNonOwnerRefusalSurfacesAsNotOwner() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.remove": rpcFailure(4030, reason: "NOT_OWNER")])
        do {
            try await customService(rpc).removeOAuthClient(slug: "figma")
            Issue.record("expected a failure")
        } catch {
            #expect((error as? ConnectAppsError)?.oauthClientFailure == .notOwner)
        }
    }
}
