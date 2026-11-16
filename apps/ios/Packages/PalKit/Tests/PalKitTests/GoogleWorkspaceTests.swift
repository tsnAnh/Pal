import Foundation
import PalConnect
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization
import Testing

private let authLink = "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&state=xyz"

private func reply(_ value: JSONValue) -> CustomRPC.Reply { { _ in value } }

private func gatewayError(_ code: Int, _ dataCode: String? = nil, message: String = "failed") -> CustomRPC.Reply {
    { _ in
        throw GatewayTransportError.rpc(RPCError(code: code, message: message, data: dataCode.map { .object(["code": .string($0)]) }))
    }
}

private func statusJSON(
    _ state: String, email: String? = nil, services: [String] = [], write: [String] = [], reason: String? = nil,
    extra: [String: JSONValue] = [:]
) -> JSONValue {
    var object: [String: JSONValue] = [
        "state": .string(state),
        "services": .array(services.map { .string($0) }),
        "write_services": .array(write.map { .string($0) }),
    ]
    if let email { object["email"] = .string(email) }
    if let reason { object["reauth_reason"] = .string(reason) }
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

private func startReply(flow: String = "flow-1", url: String = authLink) -> JSONValue {
    .object(["flow_id": .string(flow), "auth_url": .string(url), "expires_in": .int(600)])
}

private func finishReply(_ state: String, code: String? = nil, message: String? = nil, status: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["state": .string(state)]
    if let code { object["code"] = .string(code) }
    if let message { object["message"] = .string(message) }
    if let status { object["status"] = status }
    return .object(object)
}

private func service(_ rpc: any ConnectRPC, diagnostics: Diagnostics = .silent) -> GoogleWorkspaceService {
    GoogleWorkspaceService(rpc: rpc, diagnostics: diagnostics)
}

private final class ReplyQueue: Sendable {
    private let items: Mutex<[JSONValue]>

    init(_ items: [JSONValue]) { self.items = Mutex(items) }

    func next() -> JSONValue { items.withLock { $0.isEmpty ? finishReply("failed") : $0.removeFirst() } }
}

private func started(_ rpc: any ConnectRPC, diagnostics: Diagnostics = .silent) async throws -> GoogleSignInSession {
    try await service(rpc, diagnostics: diagnostics).beginSignIn(GoogleScopeSelection())
}

private func rendered(_ values: Any...) -> String {
    values.map { value in
        var dumped = ""
        dump(value, to: &dumped)
        return "\(String(describing: value))\n\(String(reflecting: value))\n\(dumped)"
    }
    .joined(separator: "\n")
}

private let signedInStatus = statusJSON("signed_in", email: "owner@example.com", services: ["gmail", "drive"], write: ["drive"])

@Suite("Google Workspace status")
struct GoogleWorkspaceStatusTests {
    @Test func decodesEveryStateOfTheContract() throws {
        let cases: [(String, GoogleWorkspaceStatus.State)] = [
            ("not_configured", .notConfigured), ("needs_sign_in", .needsSignIn), ("signed_in", .signedIn), ("reauth_needed", .reauthNeeded),
        ]
        for (raw, expected) in cases {
            #expect(try statusJSON(raw).decoded(as: GoogleWorkspaceStatus.self).state == expected)
        }
    }

    @Test func readsEmailServicesAndWriteServicesInStableOrder() throws {
        let status = try statusJSON("signed_in", email: " owner@example.com ", services: ["docs", "gmail", "gmail"], write: ["docs"])
            .decoded(as: GoogleWorkspaceStatus.self)
        #expect(status.email == "owner@example.com")
        #expect(status.services == [.gmail, .docs])
        #expect(status.writeServices == [.docs])
    }

    @Test func everyReauthReasonDecodesAndHasPlainText() throws {
        let expected: [(String, GoogleReauthReason)] = [
            ("token_missing", .tokenMissing), ("token_unreadable", .tokenUnreadable), ("revoked", .revoked), ("client_rejected", .clientRejected),
        ]
        for (raw, reason) in expected {
            let status = try statusJSON("reauth_needed", reason: raw).decoded(as: GoogleWorkspaceStatus.self)
            #expect(status.reauthReason == reason)
        }
        for reason in GoogleReauthReason.allCases {
            let text = reason.plainReason
            #expect(!text.isEmpty)
            #expect(!text.contains("_"))
            #expect(!text.contains("token_"))
        }
    }

    @Test func unknownServicesAndReasonsDoNotCrashDecoding() throws {
        let status = try statusJSON("reauth_needed", services: ["gmail", "photos", "keep"], write: ["photos"], reason: "something_new")
            .decoded(as: GoogleWorkspaceStatus.self)
        #expect(status.services == [.gmail])
        #expect(status.writeServices.isEmpty)
        #expect(status.reauthReason == .unknown)
    }

    @Test func anUnknownStateIsAFailureNotACrash() async {
        let rpc = CustomRPC(["google_workspace.status": reply(statusJSON("brand_new_state"))])
        await #expect(throws: GoogleWorkspaceError.failed) { try await service(rpc).status() }
    }

    @Test func extraKeysNeverReachTheModel() throws {
        let canary = "CANARY-" + UUID().uuidString
        let status = try statusJSON(
            "signed_in", email: "owner@example.com", services: ["gmail"],
            extra: ["client_secret": .string(canary), "access_token": .string(canary), "refresh_token": .string(canary), "path": .string("/home/" + canary)]
        ).decoded(as: GoogleWorkspaceStatus.self)
        let card = GoogleWorkspaceCardState.resolve(status: status, signingIn: false, failure: nil)
        #expect(!rendered(status, card).contains(canary))
    }
}

@Suite("Google scope selection")
struct GoogleScopeSelectionTests {
    @Test func readsDefaultToAllSixAndWritesToNone() {
        let selection = GoogleScopeSelection()
        #expect(selection.read == Set(GoogleService.allCases))
        #expect(selection.write.isEmpty)
        #expect(GoogleService.allCases.count == 6)
    }

    @Test func contactsHasNoWriteOptIn() {
        var selection = GoogleScopeSelection()
        #expect(!GoogleService.contacts.hasWriteOptIn)
        #expect(!selection.allowsWrite(.contacts))
        selection.setWrite(.contacts, true)
        #expect(selection.write.isEmpty)
        for service in GoogleService.allCases where service != .contacts { #expect(selection.allowsWrite(service)) }
    }

    @Test func writeNeedsATickedService() {
        var selection = GoogleScopeSelection()
        selection.setRead(.gmail, false)
        selection.setWrite(.gmail, true)
        #expect(selection.write.isEmpty)
        selection.setRead(.gmail, true)
        selection.setWrite(.gmail, true)
        #expect(selection.write == [.gmail])
    }

    @Test func untickingAServiceDropsItsWriteOptIn() {
        var selection = GoogleScopeSelection()
        selection.setWrite(.drive, true)
        selection.setWrite(.docs, true)
        selection.setRead(.drive, false)
        #expect(selection.write == [.docs])
        selection.setRead(.drive, true)
        #expect(!selection.write.contains(.drive))
    }

    @Test func startParamsListServicesInOrder() {
        var selection = GoogleScopeSelection()
        selection.setRead(.calendar, false)
        selection.setWrite(.docs, true)
        selection.setWrite(.gmail, true)
        let params = selection.startParams
        #expect(params["services"] == .array(["gmail", "drive", "contacts", "sheets", "docs"].map { .string($0) }))
        #expect(params["write_services"] == .array(["gmail", "docs"].map { .string($0) }))
        #expect(Set(params.keys) == ["services", "write_services"])
    }
}

@Suite("Google card state")
struct GoogleCardStateTests {
    private func status(_ state: GoogleWorkspaceStatus.State, reason: GoogleReauthReason? = nil) -> GoogleWorkspaceStatus {
        GoogleWorkspaceStatus(state: state, email: "a@b.co", services: [.gmail], writeServices: [.gmail], reauthReason: reason)
    }

    @Test func resolvesEveryState() {
        typealias Card = GoogleWorkspaceCardState
        #expect(Card.resolve(status: status(.notConfigured), signingIn: false, failure: nil) == .notConfigured)
        #expect(Card.resolve(status: status(.needsSignIn), signingIn: false, failure: nil) == .notSignedIn)
        #expect(Card.resolve(status: nil, signingIn: false, failure: nil) == .notSignedIn)
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: nil) == .signedIn(email: "a@b.co", services: [.gmail], writeServices: [.gmail]))
        #expect(Card.resolve(status: status(.reauthNeeded, reason: .revoked), signingIn: false, failure: nil) == .needsReauth(.revoked))
        #expect(Card.resolve(status: status(.reauthNeeded), signingIn: false, failure: nil) == .needsReauth(.unknown))
        #expect(Card.resolve(status: status(.signedIn), signingIn: true, failure: nil) == .signingIn)
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: "Nope.") == .failed("Nope."))
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: "  ") == .signedIn(email: "a@b.co", services: [.gmail], writeServices: [.gmail]))
    }

    @Test func everyTextIsPlainLanguage() {
        var texts = GoogleReauthReason.allCases.map(\.plainReason)
        texts += [GoogleWorkspaceCardState.notConfigured, .notSignedIn, .signingIn, .signedIn(email: nil, services: [], writeServices: [])].map(\.summary)
        let errors: [GoogleWorkspaceError] = [.ownerOnly, .notConfigured, .invalidClient, .notDesktopClient, .invalidServices, .unreachable, .signInEnded, .failed]
        texts += errors.map(\.reason)
        for text in texts {
            #expect(!text.isEmpty)
            for banned in ["4101", "4403", "5321", "google_workspace", "RPC", "token_", "invalid_", "not_desktop"] { #expect(!text.contains(banned)) }
        }
        #expect(GoogleWorkspaceCardState.signedIn(email: "a@b.co", services: [], writeServices: []).summary == "Signed in as a@b.co")
    }
}

@Suite("Google Workspace service")
struct GoogleWorkspaceServiceTests {
    @Test func statusAndVerifyAreHostLevelWithNoProfile() async throws {
        let rpc = CustomRPC(["google_workspace.status": reply(signedInStatus), "google_workspace.verify": reply(statusJSON("needs_sign_in"))])
        let status = try await service(rpc).status()
        #expect(status.state == .signedIn)
        #expect(try await service(rpc).verify().state == .needsSignIn)
        #expect(rpc.params("google_workspace.status") == [.object([:])])
        #expect(rpc.params("google_workspace.verify") == [.object([:])])
    }

    @Test func mapsGatewayErrorsToTypedFailures() async {
        let cases: [(Int, String?, GoogleWorkspaceError)] = [
            (4403, nil, .ownerOnly), (4101, "invalid_client", .invalidClient), (4101, "not_desktop_client", .notDesktopClient),
            (4101, "invalid_services", .invalidServices), (4101, "not_configured", .notConfigured), (4101, "other", .failed),
            (5321, "unreachable", .unreachable), (5321, "failed", .failed), (-32601, nil, .failed),
        ]
        for (code, dataCode, expected) in cases {
            let rpc = CustomRPC(["google_workspace.status": gatewayError(code, dataCode)])
            await #expect(throws: expected) { try await service(rpc).status() }
        }
    }

    @Test func aDroppedConnectionIsAPlainFailure() async {
        let rpc = CustomRPC(["google_workspace.verify": { _ in throw GatewayTransportError.timedOut }])
        await #expect(throws: GoogleWorkspaceError.failed) { try await service(rpc).verify() }
    }

    @Test func setClientSendsBothValuesOnce() async throws {
        let rpc = CustomRPC(["google_workspace.client.set": reply(statusJSON("needs_sign_in"))])
        let status = try await service(rpc).setClient(clientID: SecretString("id-1"), clientSecret: SecretString("secret-1"))
        #expect(status.state == .needsSignIn)
        #expect(rpc.methods() == ["google_workspace.client.set"])
        #expect(rpc.params("google_workspace.client.set") == [.object(["client_id": "id-1", "client_secret": "secret-1"])])
    }

    @Test func setClientRefusesAnEmptyValueWithoutCalling() async {
        let rpc = CustomRPC([:])
        await #expect(throws: GoogleWorkspaceError.invalidClient) {
            try await service(rpc).setClient(clientID: SecretString(""), clientSecret: SecretString("secret"))
        }
        await #expect(throws: GoogleWorkspaceError.invalidClient) {
            try await service(rpc).setClient(clientID: SecretString("id"), clientSecret: SecretString(""))
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func aRejectedClientIsReportedPlainly() async {
        let rpc = CustomRPC(["google_workspace.client.set": gatewayError(4101, "not_desktop_client")])
        await #expect(throws: GoogleWorkspaceError.notDesktopClient) {
            try await service(rpc).setClient(clientID: SecretString("id"), clientSecret: SecretString("secret"))
        }
    }

    @Test func signOutRemovesOnlyTheTokenByDefault() async throws {
        let rpc = CustomRPC(["google_workspace.signout": reply(statusJSON("needs_sign_in"))])
        _ = try await service(rpc).signOut()
        #expect(rpc.methods() == ["google_workspace.signout"])
        #expect(rpc.params("google_workspace.signout") == [.object(["remove_setup": .bool(false)])])
    }

    @Test func removeSetupIsExplicit() async throws {
        let rpc = CustomRPC(["google_workspace.signout": reply(statusJSON("not_configured"))])
        let status = try await service(rpc).signOut(removeSetup: true)
        #expect(status.state == .notConfigured)
        #expect(rpc.params("google_workspace.signout") == [.object(["remove_setup": .bool(true)])])
    }
}

@Suite("Google sign-in flow")
struct GoogleSignInFlowTests {
    private func gateway(finish: [JSONValue]) -> CustomRPC {
        let queue = ReplyQueue(finish)
        return CustomRPC([
            "google_workspace.signin.start": reply(startReply()),
            "google_workspace.signin.finish": { _ in queue.next() },
            "google_workspace.signin.cancel": reply(.object(["ok": true])),
            "google_workspace.status": reply(signedInStatus),
        ])
    }

    @Test func startSendsTheTickedServices() async throws {
        let rpc = gateway(finish: [])
        var selection = GoogleScopeSelection()
        selection.setRead(.contacts, false)
        selection.setWrite(.gmail, true)
        let session = try await service(rpc).beginSignIn(selection)
        #expect(session.authURL.absoluteString == authLink)
        let params = try #require(rpc.params("google_workspace.signin.start").first)
        #expect(params["services"]?.arrayValue?.count == 5)
        #expect(params["write_services"] == .array([.string("gmail")]))
        #expect(params["profile"] == nil)
    }

    @Test func anEmptySelectionNeverCallsTheGateway() async {
        let rpc = gateway(finish: [])
        var selection = GoogleScopeSelection()
        for service in GoogleService.allCases { selection.setRead(service, false) }
        await #expect(throws: GoogleWorkspaceError.invalidServices) { try await service(rpc).beginSignIn(selection) }
        #expect(rpc.methods().isEmpty)
    }

    @Test func refusesLinksThatAreNotHttpsGoogle() async {
        for url in ["http://accounts.google.com/o/oauth2/v2/auth", "https://evil.example.com/o/oauth2/v2/auth", "https://google.com.evil.example/auth", "https://accounts.google.com@evil.example/auth", "javascript:alert(1)"] {
            let rpc = CustomRPC([
                "google_workspace.signin.start": reply(startReply(url: url)),
                "google_workspace.signin.cancel": reply(.object(["ok": true])),
            ])
            await #expect(throws: GoogleWorkspaceError.failed) { try await started(rpc) }
            #expect(rpc.methods() == ["google_workspace.signin.start", "google_workspace.signin.cancel"])
        }
    }

    @Test func aMissingFlowIDIsAFailure() async {
        let rpc = CustomRPC(["google_workspace.signin.start": reply(.object(["auth_url": .string(authLink)]))])
        await #expect(throws: GoogleWorkspaceError.failed) { try await started(rpc) }
    }

    @Test func retryKeepsTheFlowOpenAndSignedInClosesIt() async throws {
        let rpc = gateway(finish: [finishReply("retry", code: "bad_paste", message: "Paste the whole address."), finishReply("signed_in", status: signedInStatus)])
        let session = try await started(rpc)
        #expect(await session.submit("first") == .tryAgain("Paste the whole address."))
        guard case .signedIn(let status) = await session.submit("second") else {
            Issue.record("expected signed in")
            return
        }
        #expect(status.email == "owner@example.com")
        #expect(status.writeServices == [.drive])
        let calls = rpc.methods().count
        guard case .failed = await session.submit("third") else {
            Issue.record("a closed flow must refuse")
            return
        }
        #expect(rpc.methods().count == calls)
        await session.cancel()
        #expect(rpc.methods().count == calls)
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.count == 2)
    }

    @Test func eachSubmitSendsThePasteOnceWithTheFlow() async throws {
        let rpc = gateway(finish: [finishReply("retry"), finishReply("denied", code: "denied", message: "Access was declined.")])
        let session = try await started(rpc)
        _ = await session.submit("http://127.0.0.1:1/?code=A")
        _ = await session.submit("http://127.0.0.1:1/?code=B")
        let sent = rpc.params("google_workspace.signin.finish")
        #expect(sent.map { $0["flow_id"]?.stringValue } == ["flow-1", "flow-1"])
        #expect(sent.map { $0["pasted"]?.stringValue } == ["http://127.0.0.1:1/?code=A", "http://127.0.0.1:1/?code=B"])
    }

    @Test func deniedAndFailedCloseTheFlow() async throws {
        let denied = gateway(finish: [finishReply("denied", code: "denied", message: "Access was declined.")])
        let deniedSession = try await started(denied)
        #expect(await deniedSession.submit("x") == .denied("Access was declined."))
        guard case .failed = await deniedSession.submit("y") else {
            Issue.record("denied flow must be closed")
            return
        }
        #expect(denied.params("google_workspace.signin.finish").count == 1)

        let failed = gateway(finish: [finishReply("failed", code: "expired")])
        let failedSession = try await started(failed)
        guard case .failed(let reason) = await failedSession.submit("x") else {
            Issue.record("expected failure")
            return
        }
        #expect(reason == GoogleWorkspaceError.failed.reason)
        #expect(failed.params("google_workspace.signin.finish").count == 1)
    }

    @Test func signedInWithoutAnEmbeddedStatusReadsIt() async throws {
        let rpc = gateway(finish: [finishReply("signed_in")])
        let session = try await started(rpc)
        guard case .signedIn(let status) = await session.submit("x") else {
            Issue.record("expected signed in")
            return
        }
        #expect(status.state == .signedIn)
        #expect(rpc.methods().last == "google_workspace.status")
    }

    @Test func aTransportFailureClosesTheFlowAndCancelsIt() async throws {
        let rpc = CustomRPC([
            "google_workspace.signin.start": reply(startReply()),
            "google_workspace.signin.finish": gatewayError(5321, "unreachable"),
            "google_workspace.signin.cancel": reply(.object(["ok": true])),
        ])
        let session = try await started(rpc)
        #expect(await session.submit("x") == .failed(GoogleWorkspaceError.unreachable.reason))
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.cancel" }.count == 1)
        _ = await session.submit("again")
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.count == 1)
    }

    @Test func cancelIsIdempotentAndCallsTheGatewayOnce() async throws {
        let rpc = gateway(finish: [])
        let session = try await started(rpc)
        await session.cancel()
        await session.cancel()
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.cancel" }.count == 1)
        #expect(rpc.params("google_workspace.signin.cancel") == [.object(["flow_id": "flow-1"])])
        guard case .failed = await session.submit("x") else {
            Issue.record("a cancelled flow must refuse")
            return
        }
        #expect(rpc.methods().filter { $0 == "google_workspace.signin.finish" }.isEmpty)
    }

    @Test func aSecondSubmitWhileOneIsRunningIsRefused() async throws {
        let inner = gateway(finish: [finishReply("signed_in", status: signedInStatus)])
        let session = try await started(SlowFinish(inner: inner))
        let first = Task { await session.submit("slow") }
        try await Task.sleep(for: .milliseconds(50))
        guard case .failed = await session.submit("fast") else {
            Issue.record("single flight")
            return
        }
        guard case .signedIn = await first.value else {
            Issue.record("the first submit must finish")
            return
        }
        #expect(inner.params("google_workspace.signin.finish").count == 1)
    }
}

private struct SlowFinish: ConnectRPC {
    let inner: CustomRPC

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if method == "google_workspace.signin.finish" { try await Task.sleep(for: .milliseconds(250)) }
        return try await inner.call(method, params)
    }
}

@Suite("Google Workspace in Connected apps")
struct GoogleCatalogTests {
    private func catalog(_ status: GoogleWorkspaceStatus?) -> ConnectCatalog {
        ConnectCatalog.make(hosted: [], states: [], mcp: [], google: status)
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
        #expect(ConnectCatalog.make(hosted: [], states: [], mcp: []).apps.isEmpty)
    }

    @Test func loadAddsTheRowWithoutAProfileOnTheCall() async throws {
        let rpc = CustomRPC([
            "connectors.catalog": reply(.object(["connectors": .array([])])),
            "mcp.catalog": reply(.object(["servers": .array([])])),
            "google_workspace.status": reply(signedInStatus),
        ])
        let loaded = try await customService(rpc, profile: "bot-1").load()
        #expect(loaded.apps.map(\.id) == ["google:workspace"])
        #expect(loaded.apps.first?.state == .connected)
        #expect(rpc.params("google_workspace.status") == [.object([:])])
    }

    @Test func aFailingStatusCallHidesOnlyTheGoogleRow() async throws {
        let hosted = reply(.object(["connectors": .array([.object(["slug": "slack", "name": "Slack", "description": "", "category": "Communication"])])]))
        for failure in [gatewayError(4403), gatewayError(5321, "unreachable"), gatewayError(-32601)] {
            let rpc = CustomRPC([
                "connectors.catalog": hosted, "mcp.catalog": reply(.object(["servers": .array([])])), "google_workspace.status": failure,
            ])
            let loaded = try await customService(rpc).load()
            #expect(loaded.apps.map(\.id) == ["connector:slack"])
        }
    }

    @Test func signingOutFromYourPluginsRemovesOnlyTheToken() async throws {
        let rpc = CustomRPC(["google_workspace.signout": reply(statusJSON("needs_sign_in"))])
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
        ConnectedServices(catalog: ConnectCatalog.make(hosted: [], states: [], mcp: [], google: state.map { GoogleWorkspaceStatus(state: $0) }))
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
            "google_workspace.signin.start": reply(startReply()),
            "google_workspace.signin.finish": { _ in outcomes.next() },
            "google_workspace.signin.cancel": reply(.object(["ok": true])),
            "google_workspace.client.set": { params in
                throw GatewayTransportError.rpc(RPCError(code: 4101, message: "bad \(params)", data: .object(["code": "invalid_client", "echo": .string("\(params)")])))
            },
        ])
        let google = service(rpc, diagnostics: recorder.diagnostics)
        let session = try await google.beginSignIn(GoogleScopeSelection())
        var seen = [String]()
        seen.append("\(await session.submit(pasted))")
        seen.append("\(await session.submit(pasted))")
        seen.append("\(await session.submit(pasted))")
        do {
            _ = try await google.setClient(clientID: SecretString(clientID), clientSecret: SecretString(secret))
        } catch {
            seen.append("\(error)")
            seen.append(rendered(error))
        }
        seen.append(rendered(session, google, SecretString(secret), SecretString(clientID)))
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
            "google_workspace.signin.start": reply(startReply()),
            "google_workspace.signin.finish": { params in
                throw GatewayTransportError.rpc(RPCError(code: 5321, message: "failed \(params)", data: .object(["code": "failed", "reason": .string(pasted)])))
            },
            "google_workspace.signin.cancel": reply(.object(["ok": true])),
        ])
        let session = try await started(rpc, diagnostics: recorder.diagnostics)
        let outcome = await session.submit(pasted)
        #expect(!"\(outcome)".contains(pasted))
        #expect(!recorder.transcript.contains(pasted))
        #expect(!recorder.transcript.contains("flow-1"))
        #expect(!recorder.transcript.contains("client_id"))
    }

    @Test func aDeniedStatusCarriesNoCredentialsAndNoRowLeaks() async throws {
        let canary = "CANARY-TOKEN-" + UUID().uuidString
        let leaky = statusJSON(
            "signed_in", email: "owner@example.com", services: ["gmail"],
            extra: ["client_secret": .string(canary), "access_token": .string(canary), "token": .object(["refresh_token": .string(canary)])]
        )
        let recorder = DiagnosticRecorder()
        let status = try await service(CustomRPC(["google_workspace.status": reply(leaky)]), diagnostics: recorder.diagnostics).status()
        let card = GoogleWorkspaceCardState.resolve(status: status, signingIn: false, failure: nil)
        let row = try #require(ConnectCatalog.make(hosted: [], states: [], mcp: [], google: status).apps.first)
        #expect(!rendered(status, card, row).contains(canary))

        let denied = CustomRPC([
            "connectors.catalog": reply(.object(["connectors": .array([])])),
            "mcp.catalog": reply(.object(["servers": .array([])])),
            "google_workspace.status": { _ in
                throw GatewayTransportError.rpc(RPCError(code: 4403, message: "secondary profile " + canary, data: .object(["token": .string(canary)])))
            },
        ])
        let loaded = try await ConnectAppsService(
            rpc: denied, profile: nil, browser: IdleBrowser(), diagnostics: recorder.diagnostics
        ).load()
        #expect(loaded.apps.isEmpty)
        #expect(!rendered(loaded).contains(canary))
        #expect(!recorder.transcript.contains(canary))
        await #expect(throws: GoogleWorkspaceError.ownerOnly) { try await service(denied).status() }
    }
}
