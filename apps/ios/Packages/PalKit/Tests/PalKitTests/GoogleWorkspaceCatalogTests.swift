import Foundation
import PalConnect
import PalDevice
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization
import Testing

@Suite("Google Workspace in Connected apps")
struct GoogleCatalogTests {
    private func catalog(_ status: GoogleWorkspaceStatus?) -> ConnectCatalog {
        ConnectCatalog.make(catalog: [], mcp: [], google: status)
    }

    @Test func rowStateFollowsTheStatus() throws {
        let expectations: [(GoogleWorkspaceStatus.State, ConnectAppState)] = [
            (.signedIn, .connected), (.reauthNeeded, .needsAuthorization), (.needsSignIn, .disconnected), (.notConfigured, .disconnected),
        ]
        for (state, expected) in expectations {
            let app = try #require(catalog(GoogleWorkspaceStatus(state: state, reauthReason: .revoked)).apps.first)
            #expect(app.id == "google:workspace")
            #expect(app.name == "Google Workspace")
            #expect(app.source == .googleWorkspace)
            #expect(app.category == "Files and docs")
            #expect(app.state == expected)
            #expect((app.authReason != nil) == (state == .reauthNeeded))
        }
    }

    @Test func noStatusMeansNoRow() {
        #expect(catalog(nil).apps.isEmpty)
        #expect(ConnectCatalog.make(catalog: [], mcp: []).apps.isEmpty)
    }

    @Test func loadAddsTheRowWithoutAProfileOnTheCall() async throws {
        let rpc = CustomRPC([
            "connectors.catalog": googleReply(.object(["connectors": .array([])])),
            "mcp.catalog": googleReply(.object(["servers": .array([])])),
            "google_workspace.status": googleReply(googleSignedInStatus),
        ])
        let loaded = try await customService(rpc, profile: "bot-1").load()
        #expect(loaded.apps.map(\.id) == ["google:workspace"])
        #expect(loaded.apps.first?.state == .connected)
        #expect(rpc.params("google_workspace.status") == [.object([:])])
    }

    @Test func aFailingStatusCallHidesOnlyTheGoogleRow() async throws {
        let slack: JSONValue = .object(["slug": "slack", "name": "Slack", "category": "Communication", "method": "none", "status": "not_connected"])
        let hosted = googleReply(.object(["connectors": .array([slack])]))
        for failure in [gatewayError(4403), gatewayError(5321, "unreachable"), gatewayError(-32601)] {
            let rpc = CustomRPC([
                "connectors.catalog": hosted, "mcp.catalog": googleReply(.object(["servers": .array([])])), "google_workspace.status": failure,
            ])
            let loaded = try await customService(rpc).load()
            #expect(loaded.apps.map(\.id) == ["connector:slack"])
        }
    }

    @Test func signingOutFromYourPluginsRemovesOnlyTheToken() async throws {
        let rpc = CustomRPC(["google_workspace.signout": googleReply(googleStatusJSON("needs_sign_in"))])
        let app = try #require(catalog(GoogleWorkspaceStatus(state: .signedIn)).apps.first)
        try await customService(rpc).disconnect(app)
        #expect(rpc.params("google_workspace.signout") == [.object(["remove_setup": .bool(false)])])
    }
}

private struct GatedItem: ServiceSuggestion, Equatable {
    let requiredService: ServiceKind?
}

@Suite("Google Workspace as a connected service")
struct GoogleConnectedServiceTests {
    private func services(_ state: GoogleWorkspaceStatus.State?) -> ConnectedServices {
        ConnectedServices(catalog: ConnectCatalog.make(catalog: [], mcp: [], google: state.map { GoogleWorkspaceStatus(state: $0) }))
    }

    @Test func onlyASignedInAccountCounts() {
        #expect(services(.signedIn).isConnected(.google))
        let others: [GoogleWorkspaceStatus.State?] = [.reauthNeeded, .needsSignIn, .notConfigured, nil]
        for state in others { #expect(!services(state).isConnected(.google)) }
        #expect(!ConnectedServices.unknown.isConnected(.google))
    }

    @Test func aGoogleGatedSuggestionIsHiddenUnlessConnected() {
        let item = GatedItem(requiredService: .google)
        #expect(services(.signedIn).visible([item]) == [item])
        #expect(services(.reauthNeeded).visible([item]).isEmpty)
        #expect(ConnectedServices.unknown.visible([item]).isEmpty)
        #expect(ConnectedServices(connected: [.google]).isConnected(.google))
        #expect(ServiceKind.google.connectorSlug == "google-workspace")
    }
}

@Suite("Google Workspace secrets stay out of everything")
struct GoogleCanaryTests {
    @Test func aPastedValueAndClientSecretNeverReachLogsOrDescriptions() async throws {
        let pasted = "http://127.0.0.1:55555/?code=CANARY-PASTE-" + UUID().uuidString
        let secret = "CANARY-SECRET-" + UUID().uuidString
        let clientID = "CANARY-ID-" + UUID().uuidString
        let canaries = [pasted, secret, clientID]
        let recorder = DiagnosticRecorder()
        let outcomes = ReplyQueue([
            finishReply("retry", code: "bad_paste", message: "Paste the whole address."),
            finishReply("failed", code: "expired", message: "The sign-in expired. Start again."),
        ])
        let rpc = CustomRPC([
            "google_workspace.signin.start": googleReply(startReply()),
            "google_workspace.signin.finish": { _ in outcomes.next() },
            "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
            "google_workspace.client.set": { params in
                throw GatewayTransportError.rpc(RPCError(
                    code: 4101, message: "bad \(params)", data: .object(["code": "invalid_client", "echo": .string("\(params)")])
                ))
            },
        ])
        let google = googleService(rpc, diagnostics: recorder.diagnostics)
        let session = try await google.beginSignIn(GoogleScopeSelection())
        var seen = [String]()
        seen.append("\(await session.submit(pasted))")
        seen.append("\(await session.submit(pasted))")
        seen.append("\(await session.submit(pasted))")
        do {
            _ = try await google.setClient(clientID: SecretString(clientID), clientSecret: SecretString(secret))
        } catch {
            seen.append("\(error)")
            seen.append(googleRendered(error))
        }
        seen.append(googleRendered(session, google, SecretString(secret), SecretString(clientID)))
        seen.append(recorder.transcript)
        for canary in canaries {
            for text in seen { #expect(!text.contains(canary)) }
        }
        #expect(!recorder.events.isEmpty)
    }

    @Test func aTransportFailureOnFinishLogsOnlyStaticText() async throws {
        let pasted = "CANARY-PASTE-" + UUID().uuidString
        let recorder = DiagnosticRecorder()
        let rpc = CustomRPC([
            "google_workspace.signin.start": googleReply(startReply()),
            "google_workspace.signin.finish": { params in
                throw GatewayTransportError.rpc(RPCError(code: 5321, message: "failed \(params)", data: .object(["code": "failed", "reason": .string(pasted)])))
            },
            "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
        ])
        let session = try await googleStarted(rpc, diagnostics: recorder.diagnostics)
        let outcome = await session.submit(pasted)
        #expect(!"\(outcome)".contains(pasted))
        #expect(!recorder.transcript.contains(pasted))
        #expect(!recorder.transcript.contains("flow-1"))
        #expect(!recorder.transcript.contains("client_id"))
    }

    @Test func aDeniedStatusCarriesNoCredentialsAndNoRowLeaks() async throws {
        let canary = "CANARY-TOKEN-" + UUID().uuidString
        let leaky = googleStatusJSON(
            "signed_in", email: "owner@example.com", services: ["gmail"],
            extra: ["client_secret": .string(canary), "access_token": .string(canary), "token": .object(["refresh_token": .string(canary)])]
        )
        let recorder = DiagnosticRecorder()
        let status = try await googleService(CustomRPC(["google_workspace.status": googleReply(leaky)]), diagnostics: recorder.diagnostics).status()
        let card = GoogleWorkspaceCardState.resolve(status: status, signingIn: false, failure: nil)
        let row = try #require(ConnectCatalog.make(catalog: [], mcp: [], google: status).apps.first)
        #expect(!googleRendered(status, card, row).contains(canary))

        let denied = CustomRPC([
            "connectors.catalog": googleReply(.object(["connectors": .array([])])),
            "mcp.catalog": googleReply(.object(["servers": .array([])])),
            "google_workspace.status": { _ in
                throw GatewayTransportError.rpc(RPCError(code: 4403, message: "secondary profile " + canary, data: .object(["token": .string(canary)])))
            },
        ])
        let loaded = try await ConnectAppsService(
            rpc: denied, profile: nil, browser: IdleBrowser(), diagnostics: recorder.diagnostics
        ).load()
        #expect(loaded.apps.isEmpty)
        #expect(!googleRendered(loaded).contains(canary))
        #expect(!recorder.transcript.contains(canary))
        await #expect(throws: GoogleWorkspaceError.ownerOnly) { try await googleService(denied).status() }
    }
}

private final class RouteLog: Sendable {
    private let entries = Mutex<[String]>([])
    var all: [String] { entries.withLock { $0 } }
    func note(_ entry: String) { entries.withLock { $0.append(entry) } }
}

private func fakeRoute(_ name: String, _ log: RouteLog, submit: ServicePasteOutcome = .signedIn) -> ServicePasteSignIn {
    ServicePasteSignIn(
        begin: { service in log.note("\(name).begin:\(service)"); return nil },
        submit: { service, _ in log.note("\(name).submit:\(service)"); return submit },
        cancel: { service in log.note("\(name).cancel:\(service)") },
        reopen: { service in log.note("\(name).reopen:\(service)") }
    )
}

private func googleRequired(
    _ reason: String, service: String = GoogleWorkspaceCatalog.serviceID, requestID: String = "g1"
) -> GatewayEvent {
    GatewayEvent(type: "auth.required", payload: .object([
        "request_id": .string(requestID), "service": .string(service), "service_name": "Google Workspace", "bot": "atlas",
        "bots": ["atlas"], "reason": .string(reason), "flow": "oauth_paste", "expires_in": 300, "signin_on": "owner_app",
    ]))
}

@MainActor
@Suite("Google Workspace typed re-sign-in")
struct GoogleTypedReauthTests {
    private let account = GoogleWorkspaceStatus(state: .signedIn, email: "a@b.co", services: [.gmail], writeServices: [])

    @Test func theTypedEventMapsToTheNeedsReauthState() throws {
        let expectations: [(ServiceSignInReason, GoogleReauthReason)] = [
            (.missing, .tokenMissing), (.expired, .tokenUnreadable), (.revoked, .revoked), (.unknown, .unknown),
        ]
        for (wire, expected) in expectations {
            let event = AuthRequiredEvent(
                requestID: "g1", service: GoogleWorkspaceCatalog.serviceID, serviceName: "Google Workspace", bot: "atlas",
                bots: ["atlas"], reason: wire, flow: .oauthPaste, signinOn: "owner_app"
            )
            #expect(event.requiresAppSignIn)
            #expect(GoogleReauthReason(signIn: wire) == expected)
            let card = GoogleWorkspaceCardState.resolve(status: account, signingIn: false, failure: nil, authRequired: event.reason)
            #expect(card == .needsReauth(expected))
            let listed = try #require(ConnectCatalog.make(catalog: [], mcp: [], google: account).apps.first)
            let row = listed.applyingGoogleAuthRequired(event.reason)
            #expect(row.state == .needsAuthorization)
            #expect(row.authReason == expected.plainReason)
        }
    }

    @Test func theOrderIsSigningInThenFailureThenAuthRequiredThenStatus() {
        typealias Card = GoogleWorkspaceCardState
        #expect(Card.resolve(status: account, signingIn: true, failure: "Nope.", authRequired: .revoked) == .signingIn)
        #expect(Card.resolve(status: account, signingIn: false, failure: "Nope.", authRequired: .revoked) == .failed("Nope."))
        #expect(Card.resolve(status: nil, signingIn: false, failure: nil, authRequired: .missing) == .needsReauth(.tokenMissing))
        #expect(
            Card.resolve(status: account, signingIn: false, failure: nil, authRequired: nil)
                == .signedIn(email: "a@b.co", services: [.gmail], writeServices: [])
        )
        #expect(
            Card.resolve(status: account, signingIn: false, failure: nil)
                == Card.resolve(status: account, signingIn: false, failure: nil, authRequired: nil)
        )
    }

    @Test func onlyTheGoogleRowTakesTheOverlay() throws {
        let google = try #require(ConnectCatalog.make(catalog: [], mcp: [], google: account).apps.first)
        #expect(google.applyingGoogleAuthRequired(nil) == google)
        let other = ConnectApp(
            id: "connector:slack", name: "Slack", summary: "", category: "Communication",
            source: .catalog(PalCatalogEntry(slug: "slack", name: "Slack", method: .mcpOAuth)), state: .connected
        )
        #expect(other.applyingGoogleAuthRequired(.revoked) == other)
    }

    @Test func aPendingDialogForGoogleIsTheReasonAndASignedInOneClearsIt() {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, dismissDelay: .seconds(60))
        #expect(center.pendingReason(for: GoogleWorkspaceCatalog.serviceID) == nil)
        center.receive(googleRequired("revoked"))
        #expect(center.pendingReason(for: GoogleWorkspaceCatalog.serviceID) == .revoked)
        #expect(center.pendingReason(for: "github") == nil)
        center.receive(GatewayEvent(type: "auth.resolved", payload: ["request_id": "g1", "outcome": "signed_in"]))
        #expect(center.pendingReason(for: GoogleWorkspaceCatalog.serviceID) == nil)
        let cleared = GoogleWorkspaceCardState.resolve(
            status: account, signingIn: false, failure: nil, authRequired: center.pendingReason(for: GoogleWorkspaceCatalog.serviceID)
        )
        #expect(cleared.isSignedIn)
    }

    @Test func aDeclinedDialogStopsHoldingTheRowInReauth() async {
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, dismissDelay: .seconds(60))
        center.receive(googleRequired("expired"))
        #expect(center.pendingReason(for: GoogleWorkspaceCatalog.serviceID) == .expired)
        await center.notNow()
        #expect(center.pendingReason(for: GoogleWorkspaceCatalog.serviceID) == nil)
    }

    @Test func theSignInStartsFromTheCurrentGrant() {
        let granted = GoogleWorkspaceStatus(state: .signedIn, services: [.gmail, .drive], writeServices: [.drive, .contacts, .docs])
        let selection = GoogleScopeSelection(granted: granted)
        #expect(selection.read == [.gmail, .drive])
        #expect(selection.write == [.drive])
        let reauth = GoogleScopeSelection(granted: GoogleWorkspaceStatus(state: .reauthNeeded, services: [.calendar], writeServices: [.calendar]))
        #expect(reauth.read == [.calendar] && reauth.write == [.calendar])
        let fresh = GoogleScopeSelection()
        for status in [nil, GoogleWorkspaceStatus(state: .needsSignIn, services: [.gmail]), GoogleWorkspaceStatus(state: .reauthNeeded)] {
            #expect(GoogleScopeSelection(granted: status) == fresh)
        }
        #expect(fresh.write.isEmpty)
    }

    @Test func theRouteForGoogleNeverTouchesTheOtherRoute() async {
        let log = RouteLog()
        let route = ServicePasteSignIn.routing(
            [GoogleWorkspaceCatalog.serviceID: fakeRoute("google", log)], fallback: fakeRoute("upwork", log, submit: .failed("Start again."))
        )
        let google = GoogleWorkspaceCatalog.serviceID
        _ = await route.begin(google)
        #expect(await route.submit(google, "x") == .signedIn)
        route.reopen(google)
        await route.cancel(google)
        #expect(log.all == ["google.begin:\(google)", "google.submit:\(google)", "google.reopen:\(google)", "google.cancel:\(google)"])
        _ = await route.begin("mcp:upwork")
        #expect(await route.submit("mcp:upwork", "x") == .failed("Start again."))
        #expect(log.all.suffix(2) == ["upwork.begin:mcp:upwork", "upwork.submit:mcp:upwork"])
        #expect(!log.all.dropLast(2).contains { $0.hasPrefix("upwork") })
    }

    @Test func aMacWithANativeRouteStillSignsGoogleInByPasting() async {
        let log = RouteLog()
        let center = ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in }, nativeSignIn: { _ in .failed("native") },
            pasteSignIn: .routing([GoogleWorkspaceCatalog.serviceID: fakeRoute("google", log)], fallback: fakeRoute("upwork", log)),
            pasteOnlyServices: [GoogleWorkspaceCatalog.serviceID], dismissDelay: .seconds(60)
        )
        center.receive(googleRequired("missing"))
        #expect(center.current?.automaticSignInAvailable == false)
        #expect(center.current?.canSignIn == true)
        await center.signIn()
        #expect(center.current?.phase == .pasteAddress(nil))
        await center.submitAddress("http://127.0.0.1:1/?code=c&state=s")
        #expect(center.current?.phase == .signedIn)
        #expect(log.all == ["google.begin:google:workspace", "google.submit:google:workspace"])
        center.receive(googleRequired("missing", service: "mcp:upwork", requestID: "u1"))
        #expect(center.dialogs.last?.automaticSignInAvailable == true)
    }

    @Test func aPastedAddressNeverReachesTheDialogOrTheLogs() async throws {
        let pasted = "http://127.0.0.1:55555/?code=CANARY-PASTE-" + UUID().uuidString
        let recorder = DiagnosticRecorder()
        let rpc = CustomRPC([
            "google_workspace.signin.start": googleReply(startReply()),
            "google_workspace.signin.finish": googleReply(finishReply("failed", code: "expired", message: "The sign-in expired. Start again.")),
            "google_workspace.signin.cancel": googleReply(.object(["ok": true])),
        ])
        let session = try await googleStarted(rpc, diagnostics: recorder.diagnostics)
        let route = ServicePasteSignIn(
            begin: { _ in nil },
            submit: { _, text in
                switch await session.submit(text) {
                case .signedIn: .signedIn
                case .tryAgain(let note): .tryAgain(note)
                case .denied(let reason), .failed(let reason): .failed(reason)
                }
            },
            cancel: { _ in },
            reopen: { _ in }
        )
        let center = ServiceSignInCenter(call: { _, _ in [:] }, openBrowser: { _ in }, pasteSignIn: route, dismissDelay: .seconds(60))
        center.receive(googleRequired("revoked"))
        await center.signIn()
        await center.submitAddress(pasted)
        #expect(center.current?.phase == .failed("The sign-in expired. Start again."))
        #expect(!googleRendered(center.dialogs, center.lastResolution as Any).contains(pasted))
        #expect(!recorder.transcript.contains(pasted))
    }
}
