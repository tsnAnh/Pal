import Foundation
import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

final class AdsGateway: Sendable {
    struct State: Sendable {
        var signedIn: Bool
        var configured: Bool
        var manager: String?
        var checks: [String]
        var connectPolls = 0
    }

    let state: Mutex<State>

    init(signedIn: Bool = true, configured: Bool = false, checks: [String] = ["ready"]) {
        state = Mutex(State(signedIn: signedIn, configured: configured, checks: checks))
    }

    var manager: String? { state.withLock { $0.manager } }

    func rpc(save: CustomRPC.Reply? = nil, extra: [String: CustomRPC.Reply] = [:]) -> CustomRPC {
        let status: CustomRPC.Reply = { [self] _ in
            state.withLock { current -> JSONValue in
                let manager: JSONValue = current.manager.map(JSONValue.string) ?? .null
                return [
                    "state": .string(current.signedIn ? "signed_in" : "needs_sign_in"), "configured": .bool(current.configured),
                    "login_customer_id": manager,
                ]
            }
        }
        let defaultSave: CustomRPC.Reply = { [self] params in
            state.withLock { current -> JSONValue in
                current.configured = true
                current.manager = params["login_customer_id"]?.stringValue
                let manager: JSONValue = current.manager.map(JSONValue.string) ?? .null
                return ["tools": 6, "login_customer_id": manager]
            }
        }
        let verify: CustomRPC.Reply = { [self] _ in
            state.withLock { current -> JSONValue in
                let check = current.checks.count > 1 ? current.checks.removeFirst() : (current.checks.first ?? "ready")
                let accounts: JSONValue = check == "ready" ? .int(2) : .null
                return ["check": .string(check), "accounts": accounts]
            }
        }
        let connect: CustomRPC.Reply = { _ in
            ["slug": "google-ads", "auth_url": "https://accounts.google.com/o/oauth2/v2/auth?state=s", "session_id": .null]
        }
        let catalog: CustomRPC.Reply = { [self] _ in
            state.withLock { current -> JSONValue in
                current.connectPolls += 1
                if current.connectPolls >= 2 { current.signedIn = true }
                let row: JSONValue = [
                    "slug": "google-ads", "name": "Google Ads", "method": "oauth_client",
                    "status": .string(current.signedIn ? "connected" : "not_connected"),
                ]
                return ["connectors": .array([row])]
            }
        }
        var replies: [String: CustomRPC.Reply] = [
            "connectors.google_ads.status": status, "connectors.google_ads.save": save ?? defaultSave,
            "connectors.google_ads.verify": verify, "connectors.oauth_client.connect": connect, "connectors.catalog": catalog,
        ]
        for (method, reply) in extra { replies[method] = reply }
        return CustomRPC(replies)
    }
}

@Suite("Google Ads flow steps")
struct GoogleAdsFlowStepTests {
    @Test func theWizardHasTheStepsInOrderAndHidesTheCheckFromTheChecklist() throws {
        let steps = GoogleAdsFlow.steps()
        #expect(steps.map(\.id) == ["api", "explorer", "consent", "signin", "manager", "check", "done"])
        let engine = try #require(GoogleAdsFlow.engine(status: nil))
        #expect(engine.checklist.map(\.id) == ["api", "explorer", "consent", "signin", "manager"])
        #expect(engine.checklist.map(\.title) == [
            "Enable the Google Ads API", "Apply for Explorer access", "Allow Google Ads sign-in", "Sign in", "Manager account",
        ])
        #expect(engine.positionLabel == "Step 1 of 5")
        #expect(engine.steps.last?.isSuccess == true)
    }

    @Test func eachInstructionStepOpensItsOwnGooglePage() {
        let links = GoogleAdsFlow.steps().prefix(3).map { step -> String? in
            if case .instruction(let link) = step.kind { link?.url.absoluteString } else { nil }
        }
        #expect(links == [
            "https://console.cloud.google.com/apis/library/googleads.googleapis.com",
            "https://console.cloud.google.com/apis/api/googleads.googleapis.com/overview",
            "https://console.cloud.google.com/apis/credentials/consent",
        ])
    }

    @Test func theExplorerStepSaysTheReviewIsAutomaticAndTakesMinutes() throws {
        let step = try #require(GoogleAdsFlow.steps().first { $0.id == "explorer" })
        #expect(step.body.contains("The review is automatic and takes minutes."))
    }

    @Test func theConsentStepShowsTheSameSevenDaySentenceAsGoogleWorkspaceAndTheScope() throws {
        let step = try #require(GoogleAdsFlow.steps().first { $0.id == "consent" })
        #expect(GoogleAdsFlow.testingModeSentence == "While the app is in Testing mode, Google ends the sign-in after 7 days.")
        #expect(step.body.contains(GoogleAdsFlow.testingModeSentence))
        #expect(step.body.contains("https://www.googleapis.com/auth/adwords"))
        #expect(step.body.contains("test user"))
    }

    @Test func publishingTheAppIsOnlyALaterOptionAndNotAStep() throws {
        let step = try #require(GoogleAdsFlow.steps().first { $0.id == "consent" })
        let note = try #require(step.note)
        #expect(note.contains("publish") && note.contains("sensitive") && note.contains("verify"))
        #expect(!GoogleAdsFlow.steps().contains { $0.title.localizedCaseInsensitiveContains("publish") })
    }

    @Test func theManagerStepAsksForOneVisibleOptionalFieldAndCanBeSkipped() throws {
        let step = try #require(GoogleAdsFlow.steps().first { $0.id == "manager" })
        #expect(step.fields == [SetupField(id: "manager", label: "Manager account ID (optional)", secret: false)])
        #expect(step.skipTitle == "Skip" && step.skipTarget == "check" && step.inlineRefusal)
        #expect(step.body.contains("nothing else to add"))
    }

    @Test func theSignInStepWaitsForGoogleInTheBrowser() throws {
        let step = try #require(GoogleAdsFlow.steps().first { $0.id == "signin" })
        #expect(step.primaryTitle == "Sign in with Google")
        #expect(step.kind == .browserRoundTrip(
            waitingTitle: "Waiting for Google",
            waitingBody: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done."
        ))
    }

    @Test(arguments: [
        (nil as GoogleAdsStatus?, "api"),
        (GoogleAdsStatus(state: .needsSetup, configured: false), "api"),
        (GoogleAdsStatus(state: .needsSignIn, configured: false), "api"),
        (GoogleAdsStatus(state: .needsReconnect, configured: true), "signin"),
        (GoogleAdsStatus(state: .signedIn, configured: false), "manager"),
        (GoogleAdsStatus(state: .signedIn, configured: true, loginCustomerID: "1234567890"), "check"),
    ])
    func theWizardResumesWhereTheGatewayStatusLeftOff(status: GoogleAdsStatus?, expected: String) throws {
        #expect(try #require(GoogleAdsFlow.engine(status: status)).current.id == expected)
    }

    @Test func skippingTheManagerAccountLandsOnTheCheckAndTypingEnablesSave() throws {
        var engine = try #require(GoogleAdsFlow.engine(status: GoogleAdsStatus(state: .signedIn, configured: false)))
        #expect(engine.current.id == "manager" && !engine.isPrimaryEnabled && engine.canSkip)
        engine.setValue("123-456-7890", for: "manager")
        #expect(engine.isPrimaryEnabled)
        engine.setValue("", for: "manager")
        let skipped = engine.skip()
        #expect(skipped && engine.current.id == "check")
        #expect(engine.primaryAction == .work && engine.isPrimaryEnabled)
        #expect(engine.stepNumber == 5)
    }

    @Test(arguments: [
        ("", ManagerAccountID.Parsed.skip), ("   ", .skip), ("1234567890", .id("1234567890")), ("123-456-7890", .id("1234567890")),
        (" 123 456 7890 ", .id("1234567890")), ("123\u{2013}456\u{2013}7890", .id("1234567890")), ("12ab34", .invalid),
        ("abc", .invalid), ("---", .invalid), ("123,456", .invalid), ("\u{FF11}\u{FF12}\u{FF13}", .invalid),
    ])
    func theManagerIdKeepsOnlyDigitsAndRefusesLetters(raw: String, expected: ManagerAccountID.Parsed) {
        #expect(ManagerAccountID.parse(raw) == expected)
    }
}

@Suite("Google Ads status copy")
struct GoogleAdsStatusCopyTests {
    @Test func explorerAccessNeededHasItsOwnPlainStatus() {
        let status = SetupStatus(code: "explorer_access_needed", method: "connectors.google_ads.verify", subject: "Google Ads")
        #expect(status.kind == .explorerAccessNeeded)
        #expect(status.title == "Apply for Explorer access")
        #expect(status.reason.contains("has not approved this project"))
        #expect(status.reason.contains("automatic and takes minutes"))
        #expect(!status.reason.contains("explorer_access_needed"))
        #expect(status.actionTitle == "Open Google Cloud")
        #expect(SetupStatusClass.classify(code: "EXPLORER_ACCESS_NEEDED") == .explorerAccessNeeded)
    }

    @Test func eachVerifyAnswerMapsToOneSharedStatus() {
        #expect(GoogleAdsFlow.status(for: .ready) == nil)
        #expect(GoogleAdsFlow.status(for: .explorerAccessNeeded)?.kind == .explorerAccessNeeded)
        let reauth = GoogleAdsFlow.status(for: .needsReauth)
        #expect(reauth?.kind == .needsReauth && reauth?.reason == "Google Ads needs you to sign in again." && reauth?.actionTitle == "Reconnect")
        let unreachable = GoogleAdsFlow.status(for: .unreachable)
        #expect(unreachable?.kind == .offline && unreachable?.title == "Pal could not reach Google Ads")
    }

    @Test func aMissingGoogleClientAsksForGoogleWorkspaceFirst() {
        let runner = GoogleAdsFlowRunner(service: customService(CustomRPC([:])))
        let status = runner.classify(ConnectAppsError.oauthClient(.needsSetup))
        #expect(status.title == "Set up Google Workspace first")
        #expect(status.reason.contains("Google Workspace"))
        let address = runner.classify(ConnectAppsError.oauthClient(.needsPublicURL))
        #expect(address.title == "Your Pal needs a web address")
    }

    @Test func aNonOwnerSeesTheForbiddenStatus() {
        let runner = GoogleAdsFlowRunner(service: customService(CustomRPC([:])))
        #expect(runner.classify(ConnectAppsError.oauthClient(.notOwner)).kind == .forbidden)
        let rpc = RPCError(code: 4030, message: "x", data: ["reason": "NOT_OWNER"])
        let fault = GatewayFault(rpc, method: "connectors.google_ads.save")
        #expect(runner.classify(ConnectAppsError.oauthClient(.notOwner, fault)).kind == .forbidden)
    }

    @Test func theRowSaysWhatToDoFirstWhenNoGoogleClientIsSaved() {
        let needsSetup = catalogEntry("google-ads", "Google Ads", "Monitoring and analytics", method: .oauthClient, status: .needsSetup, url: nil)
        let catalog = ConnectCatalog.make(catalog: [needsSetup], mcp: [])
        let app = catalog.apps[0]
        #expect(app.isGoogleAds && app.summary == "Save your Google sign-in under Google Workspace first.")
        #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .setUp)
        let ready = catalogEntry("google-ads", "Google Ads", "Monitoring and analytics", method: .oauthClient, url: nil)
        let row = ConnectCatalog.make(catalog: [ready], mcp: []).apps[0]
        #expect(ConnectRowState.resolve(ConnectRowInput(app: row)) == .connect)
        #expect(row.oauthClientEntry == nil)
    }
}

@Suite("Google Ads service")
struct GoogleAdsServiceTests {
    @Test func theStatusDecodesTheStateTheSavedFlagAndTheManagerId() async throws {
        let gateway = AdsGateway(signedIn: true, configured: true)
        _ = try await customService(gateway.rpc()).saveGoogleAds(loginCustomerID: "1234567890")
        let status = try await customService(gateway.rpc()).googleAdsStatus()
        #expect(status == GoogleAdsStatus(state: .signedIn, configured: true, loginCustomerID: "1234567890"))
    }

    @Test func anUnknownStateIsAFailureNotAGuess() async {
        let rpc = CustomRPC(["connectors.google_ads.status": { _ in ["state": "something_new", "configured": false] }])
        do {
            _ = try await customService(rpc).googleAdsStatus()
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConnectAppsError == .failed)
        }
    }

    @Test func saveSendsDigitsOrAnExplicitNull() async throws {
        let rpc = AdsGateway().rpc()
        let service = customService(rpc)
        try await service.saveGoogleAds(loginCustomerID: "1234567890")
        try await service.saveGoogleAds(loginCustomerID: nil)
        let sent = rpc.params("connectors.google_ads.save")
        #expect(sent.map { $0["login_customer_id"] } == [JSONValue.string("1234567890"), JSONValue.null])
    }

    @Test func verifyReadsTheCheckAndTheAccountCount() async throws {
        let ready = try await customService(AdsGateway().rpc()).verifyGoogleAds()
        #expect(ready == GoogleAdsVerification(check: .ready, accounts: 2))
        let refused = try await customService(AdsGateway(checks: ["explorer_access_needed"]).rpc()).verifyGoogleAds()
        #expect(refused == GoogleAdsVerification(check: .explorerAccessNeeded, accounts: nil))
    }

    @Test func aRefusedVerifyIsACheckValueAndAnUnknownOneIsAFailure() async {
        let rpc = CustomRPC(["connectors.google_ads.verify": { _ in ["check": "mystery", "accounts": .null] }])
        do {
            _ = try await customService(rpc).verifyGoogleAds()
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConnectAppsError == .failed)
        }
    }

    @Test func signInOpensTheConsentPageInTheSystemBrowserAndWaitsForTheRowToConnect() async throws {
        let browser = BlockingBrowser()
        let rpc = AdsGateway(signedIn: false).rpc()
        try await customService(rpc, system: browser).signInGoogleAds()
        #expect(browser.presented.withLock { $0.map(\.absoluteString) } == ["https://accounts.google.com/o/oauth2/v2/auth?state=s"])
        let connect = try #require(rpc.params("connectors.oauth_client.connect").first)
        #expect(connect["slug"]?.stringValue == "google-ads" && connect["client_redirect_uri"] == nil)
    }

    @Test func aMissingGoogleClientStopsTheSignInBeforeAnyBrowserOpens() async {
        let browser = RecordingBrowser()
        let rpc = AdsGateway(signedIn: false).rpc(extra: ["connectors.oauth_client.connect": rpcFailure(4090, reason: "NEEDS_SETUP")])
        do {
            try await customService(rpc, system: browser).signInGoogleAds()
            Issue.record("expected a failure")
        } catch {
            #expect((error as? ConnectAppsError)?.oauthClientFailure == .needsSetup)
        }
        #expect(browser.presented.withLock { $0.isEmpty })
    }

    @Test func removingTheAdsSignInKeepsTheSharedGoogleClient() async throws {
        let rpc = CustomRPC(["connectors.oauth_client.remove": { _ in ["slug": "google-ads", "removed": true] }])
        let entry = catalogEntry("google-ads", "Google Ads", "Monitoring and analytics", method: .oauthClient, status: .connected, url: nil)
        let app = ConnectCatalog.make(catalog: [entry], mcp: []).apps[0]
        try await customService(rpc).disconnect(app)
        let sent = try #require(rpc.params("connectors.oauth_client.remove").first)
        #expect(sent["slug"]?.stringValue == "google-ads" && sent["remove_client"]?.boolValue != true)
    }
}
